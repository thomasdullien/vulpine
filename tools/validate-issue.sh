#!/usr/bin/env bash
# validate-issue.sh - machine gate for a single issues/<N>-slug/ directory.
#
# Exits 0 if the directory satisfies the code-auditor verification contract,
# non-zero with a specific complaint otherwise. Run on every issue you emit;
# do not return from stage 7 until every issue in $VULPINE_RUN/issues/ passes.
#
# Usage:
#   tools/validate-issue.sh <issue-dir>          # validate one
#   tools/validate-issue.sh --all <issues-root>  # validate every subdir
set -uo pipefail  # -e off: per-check fail()+return must not abort the script

fail() { printf 'FAIL [%s]: %s\n' "$1" "$2" >&2; return 1; }
ok()   { printf 'OK   [%s] status=%s severity=%s memcorruption=%s\n' "$1" "$2" "$3" "$4"; }

# ---------- Extract the single-word status from "## Verification Status". ----
extract_status() {
  # Accept any of:
  #   ## Verification Status\nCONFIRMED\n...
  #   ## Verification Status: CONFIRMED
  #   ## Verification: CONFIRMED
  #   ## Verification\n- **CONFIRMED** — ...
  awk '
    /^## Verification( Status)?( *:.*)?$/ {in_s=1; print; next}
    in_s && /^## / {exit}
    in_s {print}
  ' "$1" \
  | tr -d '*' \
  | grep -oE 'CONFIRMED|CONTESTED|UNCONFIRMED|THEORETICAL' \
  | head -1
}

# ---------- Extract the single-word severity. Accepts:
#   ## Severity\nMedium\n
#   ## Severity: Medium
#   **Severity:** Medium
#   Severity: Medium
extract_severity() {
  local v
  # Heading form (value may be on heading line after a colon, OR on next line).
  v=$(awk '
    /^## Severity[: ]/ {in_s=1; print; next}
    /^## Severity$/   {in_s=1; next}
    in_s && /^## / {exit}
    in_s {print}
  ' "$1" \
  | tr -d '*:' | tr A-Z a-z \
  | grep -oE 'critical|high|medium|low' | head -1)
  if [ -z "$v" ]; then
    # Inline form: **Severity:** <v>  or  Severity: <v>
    v=$(grep -m1 -oiE '(\*\*)?Severity:?(\*\*)?[[:space:]]+(critical|high|medium|low)' "$1" \
        | tr A-Z a-z | grep -oE 'critical|high|medium|low' | head -1)
  fi
  echo "$v"
}

# ---------- Detect whether the report talks about a memory-corruption bug. ---
is_memory_corruption() {
  grep -qiE 'use[- ]after[- ]free|double[- ]free|out[- ]of[- ]bounds[- ](read|write)|heap[- ]buffer[- ]overflow|stack[- ]buffer[- ]overflow|type[- ]confusion|use[- ]of[- ]uninit' "$1"
}

validate_one() {
  local dir="$1"
  local report="$dir/report.md"

  [ -d "$dir" ]   || { fail "$dir" "not a directory"; return 1; }
  [ -f "$report" ] || { fail "$dir" "missing report.md"; return 1; }

  local status severity memcorr=false
  status=$(extract_status   "$report")
  severity=$(extract_severity "$report")
  is_memory_corruption "$report" && memcorr=true

  # ---- Required fields on every report. -----------------------------------
  [ -n "$status" ] \
    || { fail "$dir" "report.md lacks a '## Verification Status' section (must be one of CONFIRMED/CONTESTED/UNCONFIRMED/THEORETICAL)"; return 1; }
  [ -n "$severity" ] \
    || { fail "$dir" "report.md lacks a '## Severity' value (must be critical/high/medium/low)"; return 1; }

  # ---- Severity caps by status. -------------------------------------------
  case "$status" in
    CONTESTED)
      [ "$severity" != "critical" ] \
        || { fail "$dir" "CONTESTED caps severity at 'high' per code-auditor.md"; return 1; } ;;
    UNCONFIRMED)
      [[ "$severity" == "medium" || "$severity" == "low" ]] \
        || { fail "$dir" "UNCONFIRMED caps severity at 'medium' per code-auditor.md"; return 1; } ;;
    THEORETICAL)
      [ "$severity" = "low" ] \
        || { fail "$dir" "THEORETICAL caps severity at 'low' per code-auditor.md"; return 1; } ;;
  esac

  # ---- Evidence layer: application (daemon trigger) vs. library (harness trigger).
  # Extract the "## Evidence layer" value if present. `application` means
  # the crash was observed against the real daemon/CLI. `library` means
  # it fired via a standalone library harness — the bug is real in the
  # library but its reach from the deployed product is not proven.
  local ev_layer
  ev_layer=$(awk '/^## Evidence layer/{in_s=1; next} in_s && /^## /{exit} in_s{print}' "$report" \
             | tr -d '*' | grep -oE '\b(application|library)\b' | head -1)

  # library-layer mem-corruption caps at medium; high/critical needs application layer.
  if [ "$status" = "CONFIRMED" ] && $memcorr && [ "$ev_layer" = "library" ]; then
    case "$severity" in
      critical|high)
        fail "$dir" "CONFIRMED memory-corruption w/ Evidence layer=library caps at medium; re-trigger via a real daemon/CLI to flip to application, or downgrade severity."
        return 1 ;;
    esac
  fi
  if [ "$status" = "CONFIRMED" ] && $memcorr; then
    case "$severity" in
      critical|high)
        [ -n "$ev_layer" ] \
          || { fail "$dir" "CONFIRMED mem-corr severity=$severity requires '## Evidence layer: application' (or downgrade to medium with 'library')."; return 1; } ;;
    esac
  fi

  # ---- CONFIRMED on memory-corruption: real ASan output + verify.rr. -----
  if [ "$status" = "CONFIRMED" ] && $memcorr; then
    local asan="$dir/asan.log"
    [ -f "$asan" ] && [ -s "$asan" ] \
      || { fail "$dir" "CONFIRMED memory-corruption requires a non-empty asan.log"; return 1; }
    grep -qE '==[0-9]+==ERROR: AddressSanitizer:' "$asan" \
      || { fail "$dir" "asan.log missing real '==<pid>==ERROR: AddressSanitizer:' crash banner (empty placeholders do not count)"; return 1; }
    grep -qE '^SUMMARY: AddressSanitizer:' "$asan" \
      || { fail "$dir" "asan.log missing 'SUMMARY: AddressSanitizer:' line"; return 1; }

    # ---- Anti-fabrication. ----
    # Placeholder PIDs commonly emitted by LLMs.
    if grep -qE '^==(1|42|99|1234|12345|99999)==ERROR: AddressSanitizer:' "$asan"; then
      fail "$dir" "asan.log uses placeholder PID — fabricated output"; return 1
    fi
    # Provenance: must come from capture-asan.sh (manifest present, sha & PID match).
    local manifest="$dir/asan-run.manifest"
    [ -f "$manifest" ] \
      || { fail "$dir" "asan.log has no asan-run.manifest; run via capture-asan.sh"; return 1; }
    local m_sha f_sha
    m_sha=$(grep -oE '^asan_sha256:[[:space:]]+[0-9a-f]{64}' "$manifest" | awk '{print $2}')
    f_sha=$(sha256sum "$asan" | awk '{print $1}')
    [ -n "$m_sha" ] && [ "$m_sha" = "$f_sha" ] \
      || { fail "$dir" "asan-run.manifest sha256 mismatch — asan.log was edited after capture"; return 1; }
    local m_pid banner_pid
    m_pid=$(grep -oE '^asan_pid:[[:space:]]+[0-9]+' "$manifest" | awk '{print $2}')
    banner_pid=$(grep -oE '^==[0-9]+==ERROR: AddressSanitizer:' "$asan" | head -1 | tr -dc 0-9)
    [ -n "$m_pid" ] && [ -n "$banner_pid" ] && [ "$m_pid" = "$banner_pid" ] \
      || { fail "$dir" "asan-run.manifest PID ($m_pid) != first banner PID ($banner_pid)"; return 1; }
    # Other fabrication tells.
    grep -qiE 'AddressSanitizer:.*\(theoretical\)' "$asan" \
      && { fail "$dir" "asan.log labels itself '(theoretical)' — not a real run"; return 1; }
    if grep -qE 'on (unknown )?address 0x0+ ' "$asan" && ! grep -qE 'on (unknown )?address 0x0+[0-9a-fA-F]+' "$asan"; then
      fail "$dir" "all-zero crash address — fabricated"; return 1
    fi
    grep -qE '^SUMMARY: AddressSanitizer:.*\.\.\.' "$asan" \
      && { fail "$dir" "SUMMARY contains '...' — real ASan emits concrete file:line"; return 1; }
    # Crash must land in upstream code, not in the self-authored harness.
    local summary_path
    summary_path=$(grep -oE '^SUMMARY: AddressSanitizer: [a-zA-Z-]+ [^ ]+' "$asan" | head -1 | awk '{print $NF}')
    if [ -n "$summary_path" ]; then
      case "$summary_path" in
        */issues/*|*/trigger*|*/harness*|*/test_*|*/poc*)
          fail "$dir" "SUMMARY frame '$summary_path' is in the harness, not upstream"; return 1 ;;
      esac
    fi
    grep -qE '^ *#[0-9]+ 0x[0-9a-f]+ in .+ [^ ]+/build/[^ ]+' "$asan" 2>/dev/null \
      || { fail "$dir" "no ASan stack frame in \$VULPINE_RUN/build/ — crash not in upstream"; return 1; }

    [ -f "$dir/verify.rr" ] \
      || { fail "$dir" "CONFIRMED memory-corruption requires verify.rr script"; return 1; }

    if [ "$severity" = "critical" ]; then
      [ -d "$dir/evidence" ] \
        || { fail "$dir" "CONFIRMED CRITICAL memory-corruption requires evidence/ directory"; return 1; }
      compgen -G "$dir/evidence/root-cause-hypothesis-*.md" >/dev/null \
        || { fail "$dir" "evidence/ must contain root-cause-hypothesis-NNN.md"; return 1; }
      compgen -G "$dir/evidence/root-cause-hypothesis-*-verdict.md" >/dev/null \
        || { fail "$dir" "CONFIRMED CRITICAL requires an accepting -verdict.md in evidence/"; return 1; }
    fi
  fi

  # ---- Standalone-harness ban (CONFIRMED / CONTESTED). ----
  # Self-authored harnesses that manually construct struct state let
  # the agent forge initial conditions no real caller produces — the
  # ASan frame lands in upstream code but the bug is unreachable.
  if [ "$status" = "CONFIRMED" ] || [ "$status" = "CONTESTED" ]; then
    local c_srcs
    c_srcs=$(find "$dir" \
        \( -name '*.c' -o -name '*.cc' -o -name '*.cpp' -o -name '*.cxx' -o -name '*.C' \) \
        -not -path "*/evidence/*" 2>/dev/null | head -3)
    if [ -n "$c_srcs" ]; then
      fail "$dir" "issue dir has self-authored C/C++ source: $(echo $c_srcs | tr '\n' ' '). Drive a real daemon/CLI entry point instead, or downgrade to THEORETICAL."
      return 1
    fi
    local manifest="$dir/asan-run.manifest"
    if [ -f "$manifest" ]; then
      local argv_line first_word basename_argv
      argv_line=$(grep -h '^argv:' "$manifest" 2>/dev/null | head -1 | sed 's/^argv:[[:space:]]*//')
      if [ -n "$argv_line" ]; then
        first_word=$(echo "$argv_line" | awk '{print $1}')
        case "$first_word" in
          "$dir"/*|"${dir%/}"/*)
            fail "$dir" "manifest argv '$first_word' is inside the issue dir — invoke a real daemon/CLI wrapper instead."
            return 1 ;;
        esac
        basename_argv=$(basename "$first_word" 2>/dev/null)
        case "$basename_argv" in
          trigger|harness|poc|test_leak|test_harness|*_driver|*_trigger|*_harness|poc_*|trigger_*|harness_*|*_poc)
            fail "$dir" "manifest argv basename '$basename_argv' matches harness naming; re-drive via real entry point."
            return 1 ;;
        esac
      fi
    fi
  fi

  # ---- CONTESTED: 4 hypotheses + 4 rebuttals, no verdict. -----------------
  if [ "$status" = "CONTESTED" ]; then
    [ -d "$dir/evidence" ] \
      || { fail "$dir" "CONTESTED requires evidence/ directory"; return 1; }
    local h r
    h=$(compgen -G "$dir/evidence/root-cause-hypothesis-*.md" | grep -vE -- '-rebuttal\.md$|-verdict\.md$' | wc -l)
    r=$(compgen -G "$dir/evidence/root-cause-hypothesis-*-rebuttal.md" | wc -l)
    [ "$h" -ge 4 ] \
      || { fail "$dir" "CONTESTED requires 4 root-cause-hypothesis-NNN.md files (found $h)"; return 1; }
    [ "$r" -ge 4 ] \
      || { fail "$dir" "CONTESTED requires 4 rebuttal files (found $r)"; return 1; }
    ! compgen -G "$dir/evidence/root-cause-hypothesis-*-verdict.md" >/dev/null \
      || { fail "$dir" "CONTESTED must NOT have a -verdict.md (that is CONFIRMED)"; return 1; }
  fi

  # ---- UNCONFIRMED: explain why sanitizer didn't fire. --------------------
  if [ "$status" = "UNCONFIRMED" ]; then
    awk '/^## Verification Status/,/^## [^V]/' "$report" \
      | grep -iqE 'sanitizer|asan|did not|does not|no crash|silent' \
      || { fail "$dir" "UNCONFIRMED must explain in '## Verification Status' why no sanitizer fired"; return 1; }
  fi

  # ---- Reachability citation (all except THEORETICAL). ----
  if [ "$status" != "THEORETICAL" ]; then
    grep -iqE 'codenav (callers|reachable|body)|line-execution-checker|coverage-delta\.txt|reachability\.log|gcov output|coverage\.json|coverage\.ext-|trace\.ftrc|trace\.perfetto-trace' "$report" \
      || { fail "$dir" "report.md lacks reachability citation (codenav output, line-execution-checker, coverage-delta.txt, coverage.json, or trace.ftrc)."; return 1; }
  fi

  # ---- Evidence layer=application: real trace citation + taint-chain. ----
  if [ "$ev_layer" = "application" ] && [ "$status" != "THEORETICAL" ]; then
    grep -qE 'features/[^ ]+/(coverage\.json|coverage\.ext-[^ ]+\.json|trace\.ftrc(\.ext-[^ ]+)?|trace\.perfetto-trace)' "$report" \
      || { fail "$dir" "Evidence layer=application requires citation of features/<F>/coverage.json (or coverage.ext, trace.ftrc, trace.perfetto-trace)."; return 1; }
    local tc="$dir/taint-chain.md"
    [ -f "$tc" ] && [ -s "$tc" ] \
      || { fail "$dir" "Evidence layer=application requires non-empty taint-chain.md (rr-backed provenance)."; return 1; }
    local tc_class
    tc_class=$(grep -oiE '^## Classification:[[:space:]]*(attacker-controlled|constant|sentinel|clamped|harness-forged|propagated)' "$tc" \
               | tail -1 | awk -F: '{print $2}' | tr -d ' ' | tr A-Z a-z)
    [ -n "$tc_class" ] \
      || { fail "$dir" "taint-chain.md lacks '## Classification:' line (expected attacker-controlled|constant|sentinel|clamped|harness-forged)."; return 1; }
    if [ "$tc_class" != "attacker-controlled" ]; then
      fail "$dir" "taint-chain.md classification='$tc_class' — application layer requires 'attacker-controlled'; otherwise downgrade."
      return 1
    fi
  fi

  # ---- Non-THEORETICAL: trigger-attached artefacts required. --------------
  if [ "$status" != "THEORETICAL" ]; then
    [ -f "$dir/plain-rerun.log"    ] || { fail "$dir" "non-THEORETICAL requires plain-rerun.log";    return 1; }
    [ -f "$dir/verify.gdb"         ] || { fail "$dir" "non-THEORETICAL requires verify.gdb";         return 1; }
    [ -f "$dir/coverage-delta.txt" ] || { fail "$dir" "non-THEORETICAL requires coverage-delta.txt"; return 1; }
  fi

  ok "$dir" "$status" "$severity" "$memcorr"
}

# ---------- CLI ---------------------------------------------------------------
if [ $# -eq 0 ]; then
  echo "usage: $0 <issue-dir>" >&2
  echo "       $0 --all <issues-root>" >&2
  exit 2
fi

if [ "$1" = "--all" ]; then
  [ $# -ge 2 ] || { echo "--all needs an issues-root" >&2; exit 2; }
  root="$2"
  [ -d "$root" ] || { echo "not a directory: $root" >&2; exit 2; }
  pass=0; failc=0
  shopt -s nullglob
  for d in "$root"/*/; do
    d="${d%/}"
    [ -f "$d/report.md" ] || continue
    if validate_one "$d"; then
      pass=$((pass+1))
    else
      failc=$((failc+1))
    fi
  done
  printf '\n=== validate-issue summary: %d passed, %d failed ===\n' "$pass" "$failc"
  [ "$failc" -eq 0 ]
else
  validate_one "$1"
fi

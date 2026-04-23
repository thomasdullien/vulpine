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

# ---------- Extract the single-word severity from "## Severity". -------------
extract_severity() {
  awk '
    /^## Severity/ {in_s=1; next}
    in_s && /^## / {exit}
    in_s {print}
  ' "$1" \
  | tr -d '* ' \
  | tr A-Z a-z \
  | grep -oE 'critical|high|medium|low' \
  | head -1
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

  # Cap: a library-level CONFIRMED memory-corruption finding cannot be
  # tagged high or critical, because we have not proven the daemon
  # calls the function the vulnerable way. Escalation requires a
  # shape-1 (real-daemon) trigger, which flips the evidence layer to
  # `application`.
  if [ "$status" = "CONFIRMED" ] && $memcorr && [ "$ev_layer" = "library" ]; then
    case "$severity" in
      critical|high)
        fail "$dir" "CONFIRMED memory-corruption with '## Evidence layer: library' caps severity at medium. Re-trigger via a shape-1 daemon/CLI entry point (configure-target.sh --asan + crafted bytes) to upgrade to '## Evidence layer: application'."
        return 1
        ;;
    esac
  fi

  # When a CONFIRMED mem-corruption report is tagged high or critical,
  # it MUST declare an evidence layer. Silence here means the report
  # hasn't answered "library crash or product-reachable crash?".
  if [ "$status" = "CONFIRMED" ] && $memcorr; then
    case "$severity" in
      critical|high)
        [ -n "$ev_layer" ] \
          || { fail "$dir" "CONFIRMED memory-corruption with severity=$severity requires a '## Evidence layer: application' section proving the crash was observed against the real daemon/CLI (not a library harness). Add the section or downgrade to medium with 'Evidence layer: library'."; return 1; }
        ;;
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

    # ---- Anti-fabrication checks. ---------------------------------------
    # (a) Reject canned placeholder PIDs commonly emitted by LLMs.
    if grep -qE '^==(1|42|99|1234|12345|99999)==ERROR: AddressSanitizer:' "$asan"; then
      fail "$dir" "asan.log uses a placeholder PID (==12345==, ==1234==, ==1==, etc.) — real ASan runs emit process-specific PIDs, this is fabricated output"; return 1
    fi
    # (a2) Provenance manifest check: asan.log must have been produced by
    #      capture-asan.sh, which writes a matching asan-run.manifest.
    local manifest="$dir/asan-run.manifest"
    if [ ! -f "$manifest" ]; then
      fail "$dir" "asan.log has no accompanying asan-run.manifest; run via \$VULPINE_ROOT/tools/capture-asan.sh so the sanitizer output can be attributed to a real process"; return 1
    fi
    # Manifest sha256 must match current asan.log content (catches hand-edits).
    local m_sha f_sha
    m_sha=$(grep -oE '^asan_sha256:[[:space:]]+[0-9a-f]{64}' "$manifest" | awk '{print $2}')
    f_sha=$(sha256sum "$asan" | awk '{print $1}')
    [ -n "$m_sha" ] && [ "$m_sha" = "$f_sha" ] \
      || { fail "$dir" "asan-run.manifest sha256 does not match asan.log — the file was hand-edited after capture, or the manifest is stale"; return 1; }
    # Manifest's asan_pid must match the first banner's PID.
    local m_pid banner_pid
    m_pid=$(grep -oE '^asan_pid:[[:space:]]+[0-9]+' "$manifest" | awk '{print $2}')
    banner_pid=$(grep -oE '^==[0-9]+==ERROR: AddressSanitizer:' "$asan" | head -1 | tr -dc 0-9)
    [ -n "$m_pid" ] && [ -n "$banner_pid" ] && [ "$m_pid" = "$banner_pid" ] \
      || { fail "$dir" "asan-run.manifest PID ($m_pid) does not match first banner PID ($banner_pid) — fabricated output would not have a matching manifest"; return 1; }
    # (b) Reject literal '(theoretical)' self-admission in the banner.
    if grep -qiE 'AddressSanitizer:.*\(theoretical\)' "$asan"; then
      fail "$dir" "asan.log self-identifies as '(theoretical)' — this is not a real sanitizer run"; return 1
    fi
    # (c) Reject all-zero crash addresses (ASan always prints real addresses).
    if grep -qE 'on (unknown )?address 0x0+ ' "$asan" && ! grep -qE 'on (unknown )?address 0x0+[0-9a-fA-F]+' "$asan"; then
      fail "$dir" "asan.log 'on address 0x00000000...' without a real address — fabricated output"; return 1
    fi
    # (d) Reject ellipsis in the SUMMARY (real ASan emits a concrete file:line and function).
    if grep -qE '^SUMMARY: AddressSanitizer:.*\.\.\.' "$asan"; then
      fail "$dir" "asan.log SUMMARY contains '...' — real ASan emits concrete file:line and function name"; return 1
    fi
    # (e) Crash must be in the upstream target, not in the self-authored
    #     trigger/harness inside the issue directory. Check both the #0
    #     frame and the SUMMARY line.
    local summary_path
    summary_path=$(grep -oE '^SUMMARY: AddressSanitizer: [a-zA-Z-]+ [^ ]+' "$asan" | head -1 | awk '{print $NF}')
    if [ -n "$summary_path" ]; then
      case "$summary_path" in
        */issues/*|*/trigger*|*/harness*|*/test_*|*/poc*)
          fail "$dir" "asan.log SUMMARY frame '$summary_path' lands inside the self-authored trigger/harness, not in the upstream target. Re-run the trigger so the crash fires inside the real binary/daemon."; return 1
          ;;
      esac
    fi
    # (f) Require at least one stack frame (#0 or #1) pointing inside the
    #     build/ tree (upstream source), proving the crash happened in the
    #     real target rather than entirely in harness code.
    if ! grep -qE '^ *#[0-9]+ 0x[0-9a-f]+ in .+ [^ ]+/build/[^ ]+' "$asan" 2>/dev/null; then
      fail "$dir" "asan.log has no stack frame that lands in \$VULPINE_RUN/build/ — the crash did not happen in real upstream code"; return 1
    fi

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

  # ---- Standalone-harness ban (for CONFIRMED / CONTESTED). ----------------
  # Common failure mode: agent writes a .c file that manually constructs
  # struct state with attacker-chosen field values, compiles it, links
  # against the ASan-built upstream library, runs it. The ASan frame
  # lands in real upstream code (so the earlier harness-frame check
  # passes) but the initial conditions the struct is seeded with are
  # unreachable from any real calling convention — the vulnerable
  # function has no caller that would pass the required struct shape,
  # or the public API's constructor validates the parameters the
  # harness directly wrote.
  #
  # The ban: a CONFIRMED or CONTESTED issue directory may not contain
  # self-authored C/C++ source, and its asan-run.manifest argv may not
  # invoke a binary inside the issue directory or a binary whose
  # basename matches the harness naming patterns. Trigger must go
  # through a real entry point (daemon wrapper, upstream-shipped CLI,
  # or a client script feeding bytes to the real target).
  if [ "$status" = "CONFIRMED" ] || [ "$status" = "CONTESTED" ]; then
    local c_srcs
    c_srcs=$(find "$dir" \
        \( -name '*.c' -o -name '*.cc' -o -name '*.cpp' -o -name '*.cxx' -o -name '*.C' \) \
        -not -path "*/evidence/*" 2>/dev/null | head -3)
    if [ -n "$c_srcs" ]; then
      fail "$dir" "issue directory contains self-authored C/C++ source (standalone harness): $(echo $c_srcs | tr '\n' ' '). Trigger must invoke a real daemon/CLI entry point: configure-target.sh --asan + bytes on the wire via a client tool (curl / nc / python3 / vendor CLI), or an upstream-shipped CLI invoked through the run-asan-<name>.sh wrapper emitted by stage 1. Standalone library harnesses are banned because they let the agent forge initial conditions no real caller produces — move the repro into bytes fed to the real binary, or downgrade to THEORETICAL."
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
            fail "$dir" "asan-run.manifest argv begins with '$first_word' — a binary inside the issue directory. Standalone harnesses are banned; trigger must invoke a real daemon/CLI wrapper (e.g. build/run-asan-<name>.sh, upstream CLI under build/build-asan/, or a system client tool like curl/nc/python3 speaking the target's protocol)."
            return 1
            ;;
        esac
        basename_argv=$(basename "$first_word" 2>/dev/null)
        case "$basename_argv" in
          trigger|harness|poc|test_leak|test_harness|*_driver|*_trigger|*_harness|poc_*|trigger_*|harness_*|*_poc)
            fail "$dir" "asan-run.manifest argv invokes '$basename_argv' — matches the standalone-harness naming pattern. Re-drive the trigger through a real entry point (daemon wrapper or system CLI). A harness that calls library functions directly cannot prove reachability from the deployed product."
            return 1
            ;;
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

  # ---- Reachability evidence citation (for CONFIRMED / CONTESTED / UNCONFIRMED).
  # THEORETICAL is exempt — by definition no trigger reached the code. For
  # everything else, the report must cite at least one tool-output as
  # evidence of reachability; prose-only reachability claims fail the gate.
  if [ "$status" != "THEORETICAL" ]; then
    grep -iqE 'codenav (callers|reachable|body)|line-execution-checker|coverage-delta\.txt|reachability\.log|gcov output|trace\.ftrc|trace\.perfetto-trace' "$report" \
      || { fail "$dir" "report.md lacks a reachability-evidence citation (expected mention of 'codenav callers/reachable/body', 'line-execution-checker', 'coverage-delta.txt', or a 'features/<F>/trace.ftrc(.ext-<sym>)' trace file). Prose-only reachability claims are insufficient."; return 1; }
  fi

  # ---- Evidence layer: application — require REAL trace citation +
  #      taint-chain.md whose final classification is attacker-controlled.
  # This closes the failure mode where a harness forges internal state
  # (a struct manually constructed with attacker-chosen field values,
  # a buffer hand-built with a malformed prefix, a decoder context
  # initialised past a public-API sanity check) so the crash frame
  # lands in upstream code but the initial conditions are not reachable
  # from any public entry. Static reachability plus a crash is not
  # enough — the suspect value must be traced back to an attacker byte
  # via rr.
  if [ "$ev_layer" = "application" ] && [ "$status" != "THEORETICAL" ]; then
    # The reachability citation must name a real trace file (stage-5 or
    # fuzzer-extension), not just a codenav call-graph path.
    grep -qE 'features/[^ ]+/trace\.ftrc(\.ext-[^ ]+)?|features/[^ ]+/trace\.perfetto-trace' "$report" \
      || { fail "$dir" "Evidence layer=application requires the reachability section to cite a real cppfunctrace capture ('features/<F>/trace.ftrc' or 'features/<F>/trace.ftrc.ext-<sym>') proving the vulnerable function fired under a real daemon/CLI run. A codenav-only citation is insufficient here."; return 1; }

    local tc="$dir/taint-chain.md"
    [ -f "$tc" ] && [ -s "$tc" ] \
      || { fail "$dir" "Evidence layer=application requires a non-empty taint-chain.md per code-auditor §Taint-chain workflow (rr-backed provenance of the suspect parameter)."; return 1; }

    # The final classification line MUST say attacker-controlled. Anything
    # else means the bug relies on a constant / clamped / sentinel /
    # harness-forged initial condition and cannot be claimed at
    # application layer.
    local tc_class
    tc_class=$(grep -oiE '^## Classification:[[:space:]]*(attacker-controlled|constant|sentinel|clamped|harness-forged|propagated)' "$tc" \
               | tail -1 | awk -F: '{print $2}' | tr -d ' ' | tr A-Z a-z)
    [ -n "$tc_class" ] \
      || { fail "$dir" "taint-chain.md lacks a '## Classification: <verdict>' line (expected attacker-controlled | constant | sentinel | clamped | harness-forged)"; return 1; }
    if [ "$tc_class" != "attacker-controlled" ]; then
      fail "$dir" "taint-chain.md classification='$tc_class' — Evidence layer=application requires 'attacker-controlled'. If the suspect value traces to a constant/sentinel/clamped/harness-forged origin, downgrade to Evidence layer: library (or THEORETICAL) per code-auditor §Taint-chain workflow."
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

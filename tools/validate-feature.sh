#!/usr/bin/env bash
# validate-feature.sh — gate per-feature stage-5 output.
#
# Every feature dir under $VULPINE_RUN/features/ must carry the full
# mapping artefact set. If the target ships a daemon (detected via
# presence of $VULPINE_RUN/build/run-traced-<name>.sh for any name OTHER
# than "harness-*"), the trace MUST be a real cppfunctrace capture from
# the daemon, not a skip. The live bake-off showed agents repeatedly
# skipping the daemon trace for slapd/krb5kdc targets even when the
# traced wrappers existed; this gate closes that loophole.
#
# Usage:
#   tools/validate-feature.sh <feature-dir>
#   tools/validate-feature.sh --all <features-root>

set -uo pipefail

fail() { printf 'FAIL [%s]: %s\n' "$1" "$2" >&2; return 1; }
ok()   { printf 'OK   [%s]\n' "$1"; }

# ---- Detect "target has a daemon/CLI we should trace". -----------------
has_daemon() {
    local run="$1"
    compgen -G "$run/build/run-traced-*.sh" >/dev/null 2>&1 || return 1
    # Library-only targets get run-traced-harness-*.sh; exclude those.
    for f in "$run"/build/run-traced-*.sh; do
        [[ $(basename "$f") == run-traced-harness-* ]] || return 0
    done
    return 1
}

validate_one() {
    local dir="$1"
    local feat=$(basename "$dir")

    [ -d "$dir" ] || { fail "$dir" "not a directory"; return 1; }

    # Resolve VULPINE_RUN from the feature-dir path.
    local run="${dir%/features/*}"
    [ -d "$run/build" ] || { fail "$feat" "cannot resolve VULPINE_RUN from $dir"; return 1; }

    # ---- Required artefacts (daemon or library). --------------------
    [ -s "$dir/fuzz.sh" ]               || { fail "$feat" "missing or empty fuzz.sh";               return 1; }
    [ -s "$dir/functions.txt" ]         || { fail "$feat" "missing or empty functions.txt";         return 1; }
    [ -s "$dir/coverage.json" ]         || { fail "$feat" "missing or empty coverage.json";         return 1; }
    [ -s "$dir/baseline.coverage.json" ]|| { fail "$feat" "missing or empty baseline.coverage.json";return 1; }
    [ -s "$dir/sanity.json" ]           || { fail "$feat" "missing or empty sanity.json";           return 1; }

    # ---- Daemon-trace requirement. ---------------------------------
    if has_daemon "$run"; then
        [ -s "$dir/trace.ftrc" ] \
            || { fail "$feat" "target ships a daemon (run-traced-*.sh in build/) but features/$feat/trace.ftrc is missing or empty. Use 'configure-target.sh --traced' to capture it."; return 1; }
        [ -s "$dir/trace.perfetto-trace" ] \
            || { fail "$feat" "trace.ftrc present but trace.perfetto-trace missing. Run 'ftrc2perfetto trace.ftrc -o trace.perfetto-trace'."; return 1; }
    fi

    # ---- Sanity.json invariants. ---------------------------------
    # entry_points_seen non-empty; coverage_delta > 0; top_n_justifications populated.
    local sj="$dir/sanity.json"
    python3 - "$sj" "$feat" <<'PY' || return 1
import json, sys
sj_path, feat = sys.argv[1], sys.argv[2]
try:
    d = json.loads(open(sj_path).read())
except Exception as e:
    print(f"FAIL [{feat}]: sanity.json unparseable: {e}", file=sys.stderr)
    sys.exit(1)
if not d.get("entry_points_seen"):
    print(f"FAIL [{feat}]: sanity.json entry_points_seen is empty — fuzzer did not reach the feature's documented entry point", file=sys.stderr)
    sys.exit(1)
if d.get("coverage_delta", 0) < 5:
    print(f"FAIL [{feat}]: sanity.json coverage_delta={d.get('coverage_delta')} is below the 5-function floor — baseline is hitting the same code as the feature", file=sys.stderr)
    sys.exit(1)
if not d.get("top_n_justifications"):
    print(f"FAIL [{feat}]: sanity.json top_n_justifications empty — spot-check not recorded", file=sys.stderr)
    sys.exit(1)
PY

    ok "$feat"
}

# ---- CLI -------------------------------------------------------------
if [ $# -eq 0 ]; then
    echo "usage: $0 <feature-dir>" >&2
    echo "       $0 --all <features-root>" >&2
    exit 2
fi

if [ "$1" = "--all" ]; then
    [ $# -ge 2 ] || { echo "--all needs a features-root" >&2; exit 2; }
    root="$2"
    pass=0; failc=0
    shopt -s nullglob
    for d in "$root"/*/; do
        d="${d%/}"
        # Skip files that happen to live at the same level (README.md, etc).
        [ -d "$d" ] && [ -e "$d/functions.txt" -o -e "$d/fuzz.sh" ] || continue
        if validate_one "$d"; then
            pass=$((pass+1))
        else
            failc=$((failc+1))
        fi
    done
    printf '\n=== validate-feature summary: %d passed, %d failed ===\n' "$pass" "$failc"
    [ "$failc" -eq 0 ]
else
    validate_one "$1"
fi

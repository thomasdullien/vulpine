#!/usr/bin/env bash
# capture-asan.sh - run a command, capture its stderr (where ASan prints),
# and write a provenance manifest so validate-issue.sh can tell a real
# sanitizer run from hand-written fiction.
#
# Usage:
#   capture-asan.sh <issue-dir> -- <command...>
# Effect:
#   writes <issue-dir>/asan.log          full combined stdout+stderr
#         <issue-dir>/asan-run.manifest  provenance (start, end, argv, pid, sha256)
#
# The manifest captures the real runtime PID and a hash of the log; the
# validator refuses asan.log files whose content doesn't match the manifest
# or whose PID is a well-known placeholder (==12345==, ==1==, etc.).

set -euo pipefail

usage() { echo "usage: $0 <issue-dir> -- <command...>" >&2; exit 2; }

[ $# -ge 3 ] || usage
dir="$1"; shift
[ "$1" = "--" ] || usage
shift

[ -d "$dir" ] || { echo "not a directory: $dir" >&2; exit 2; }

asan_log="$dir/asan.log"
manifest="$dir/asan-run.manifest"

rm -f "$asan_log" "$manifest"

start=$(date -Is)
# Launch the target; don't let a non-zero exit abort us — ASan exits
# with various codes depending on abort_on_error/halt_on_error.
set +e
"$@" > "$asan_log" 2>&1
status=$?
set -e
end=$(date -Is)

# Extract the first ==<PID>==ERROR banner's PID if present; helps the
# validator compare against a real runtime PID.
asan_pid=$(grep -oE '^==[0-9]+==ERROR: AddressSanitizer:' "$asan_log" \
           | head -1 | tr -dc 0-9 || true)

sha=$(sha256sum "$asan_log" | awk '{print $1}')
size=$(stat -c %s "$asan_log")

cat > "$manifest" <<EOF
start:        $start
end:          $end
argv:         $*
cwd:          $(pwd -P)
uname:        $(uname -srmo)
exit_status:  $status
asan_pid:     ${asan_pid:-<none>}
asan_sha256:  $sha
asan_bytes:   $size
EOF

# Echo a one-liner for the agent/orchestrator to pick up.
echo "captured $asan_log (bytes=$size asan_pid=${asan_pid:-none} exit=$status)"

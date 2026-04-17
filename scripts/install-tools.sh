#!/usr/bin/env bash
# Clone the upstream tool repos and (where a build is defined) build them.
# Each upstream repo ships its own SKILL.md; deploy-claude.sh and
# deploy-opencode.sh wire those directories into the user's agent config.
#
# Idempotent: reruns fast-forward each repo.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$ROOT/tools/src"
BIN="$ROOT/tools/bin"
mkdir -p "$SRC" "$BIN"

clone_or_pull() {
    local url="$1" dir="$2"
    if [[ -d "$dir/.git" ]]; then
        git -C "$dir" pull --ff-only
    else
        git clone "$url" "$dir"
    fi
}

echo "[vulpine] Fetching cppfunctrace..."
clone_or_pull https://github.com/thomasdullien/cppfunctrace "$SRC/cppfunctrace"

echo "[vulpine] Fetching codenav..."
clone_or_pull https://github.com/thomasdullien/codenav "$SRC/codenav"

echo "[vulpine] Fetching ffmpeg-patch-analysis-claude (hosts gcov-coverage, rr-debugger, line-execution-checker, function-tracing skills)..."
clone_or_pull https://github.com/thomasdullien/ffmpeg-patch-analysis-claude "$SRC/ffmpeg-patch-analysis-claude"

echo "[vulpine] Fetching fnaudit (function-audit-log CLI + skill)..."
clone_or_pull https://github.com/thomasdullien/fnaudit "$SRC/fnaudit"

echo "[vulpine] Installing fnaudit CLI..."
if command -v pipx >/dev/null 2>&1; then
    pipx install --force "$SRC/fnaudit"
    # pipx already places the entry point on PATH.
else
    # Fall back to a dedicated venv under tools/venv/ (avoids PEP 668 on
    # modern Debian/Ubuntu). Symlink the fnaudit entry point into ~/.local/bin,
    # which is normally already on PATH.
    VENV="$ROOT/tools/venv"
    if [[ ! -d "$VENV" ]]; then
        python3 -m venv "$VENV"
    fi
    "$VENV/bin/pip" install --upgrade "$SRC/fnaudit"
    mkdir -p "$HOME/.local/bin"
    ln -sf "$VENV/bin/fnaudit" "$HOME/.local/bin/fnaudit"
    echo "[vulpine] fnaudit installed into venv and symlinked at $HOME/.local/bin/fnaudit"
fi

# Build whichever of these have a Makefile. The SKILL.md files typically
# do their own lazy build on first use, but a pre-build here keeps the
# first agent run fast.
for repo in cppfunctrace codenav; do
    if [[ -f "$SRC/$repo/Makefile" ]]; then
        echo "[vulpine] Building $repo..."
        make -C "$SRC/$repo" || echo "[vulpine] WARN: build of $repo failed — skill's own lazy build may still succeed."
    fi
done

# Link any produced binaries into tools/bin for convenience.
find "$SRC" -maxdepth 4 -type f -perm -111 \
    \( -name 'codenav' -o -name 'cppfunctrace*' -o -name 'line-checker' -o -name 'trace_to_perfetto' \) \
    -exec ln -sf {} "$BIN/" \; 2>/dev/null || true

echo "[vulpine] Done. Repos under $SRC/, binaries/symlinks in $BIN/."

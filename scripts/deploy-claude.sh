#!/usr/bin/env bash
# Install Vulpine into the user-scope Claude Code config dir.
#
# Agents:  .claude/agents/*.md                                            → $CLAUDE_CONFIG_DIR/agents/
# Skills (all sourced from upstream repos cloned by install-tools.sh):
#   tools/src/cppfunctrace/skill                                          → $CLAUDE_CONFIG_DIR/skills/cppfunctrace
#   tools/src/codenav                                                     → $CLAUDE_CONFIG_DIR/skills/codenav
#   tools/src/ffmpeg-patch-analysis-claude/gcov-coverage                  → $CLAUDE_CONFIG_DIR/skills/gcov-coverage
#   tools/src/ffmpeg-patch-analysis-claude/rr-debugger                    → $CLAUDE_CONFIG_DIR/skills/rr-debugger
#   tools/src/ffmpeg-patch-analysis-claude/line-execution-checker         → $CLAUDE_CONFIG_DIR/skills/line-execution-checker
#   tools/src/ffmpeg-patch-analysis-claude/function-tracing               → $CLAUDE_CONFIG_DIR/skills/function-tracing
#   tools/src/fnaudit/.claude/skills/fnaudit                              → $CLAUDE_CONFIG_DIR/skills/fnaudit
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
SRC="$ROOT/tools/src"

if [[ ! -d "$SRC" ]]; then
    echo "[vulpine] tools/src/ not found — run scripts/install-tools.sh first." >&2
    exit 1
fi

mkdir -p "$DEST/agents" "$DEST/skills"

echo "[vulpine] Linking Claude Code agents into $DEST/agents/"
for f in "$ROOT"/.claude/agents/*.md; do
    ln -sf "$f" "$DEST/agents/$(basename "$f")"
done

echo "[vulpine] Linking upstream skills into $DEST/skills/"
link_skill() {
    local name="$1" src="$2"
    if [[ -d "$src" ]]; then
        ln -sfn "$src" "$DEST/skills/$name"
        echo "  $name → $src"
    else
        echo "  [skip] $name — $src not present (did install-tools.sh finish cleanly?)" >&2
    fi
}

link_skill cppfunctrace            "$SRC/cppfunctrace/skill"
link_skill codenav                 "$SRC/codenav"
link_skill gcov-coverage           "$SRC/ffmpeg-patch-analysis-claude/gcov-coverage"
link_skill rr-debugger             "$SRC/ffmpeg-patch-analysis-claude/rr-debugger"
link_skill line-execution-checker  "$SRC/ffmpeg-patch-analysis-claude/line-execution-checker"
link_skill function-tracing        "$SRC/ffmpeg-patch-analysis-claude/function-tracing"
link_skill fnaudit                 "$SRC/fnaudit/.claude/skills/fnaudit"

echo "[vulpine] Installed. Start 'claude' and say:"
echo "   Use vulpine-orchestrator for https://github.com/<org>/<repo> at <commit>"

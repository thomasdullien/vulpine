#!/usr/bin/env bash
# Install Vulpine into the user-scope OpenCode config dir.
#
# OpenCode has no native "skills" concept; Vulpine's agent prompts reference
# skill content via absolute paths under $HOME/.vulpine/skills, so we:
#
#   1. Materialize expanded agents into $OPENCODE_CONFIG_DIR/agents/.
#   2. Link the commands into $OPENCODE_CONFIG_DIR/commands/.
#   3. Materialize a $HOME/.vulpine/skills/ tree pointing at the same upstream
#      SKILL.md directories that deploy-claude.sh uses — so both platforms read
#      the same skill text.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST="${OPENCODE_CONFIG_DIR:-$HOME/.config/opencode}"
SKILLS="${VULPINE_SKILLS_DIR:-$HOME/.vulpine/skills}"
SRC="$ROOT/tools/src"

if [[ ! -d "$SRC" ]]; then
    echo "[vulpine] tools/src/ not found — run scripts/install-tools.sh first." >&2
    exit 1
fi

mkdir -p "$DEST/agents" "$DEST/commands" "$SKILLS"

echo "[vulpine] Materializing expanded OpenCode agents into $DEST/agents/"
for f in "$ROOT"/.opencode/agents/*.md; do
    out="$DEST/agents/$(basename "$f")"
    python3 - "$ROOT" "$f" "$out" <<'PY'
import pathlib
import re
import sys

root = pathlib.Path(sys.argv[1])
src = pathlib.Path(sys.argv[2])
dst = pathlib.Path(sys.argv[3])

include_re = re.compile(r"^@(\.claude/agents/[A-Za-z0-9_.-]+\.md)\s*$")

def strip_frontmatter(text: str) -> str:
    lines = text.splitlines()
    if lines and lines[0].strip() == "---":
        for i in range(1, len(lines)):
            if lines[i].strip() == "---":
                return "\n".join(lines[i + 1:]).lstrip() + "\n"
    return text

def expand_file(path: pathlib.Path, seen: set[pathlib.Path]) -> str:
    path = path.resolve()
    if path in seen:
        raise SystemExit(f"recursive include while expanding {path}")
    seen.add(path)
    out = []
    for line in path.read_text().splitlines():
        m = include_re.match(line)
        if not m:
            out.append(line)
            continue
        inc = (root / m.group(1)).resolve()
        if not inc.is_file():
            raise SystemExit(f"missing include {inc} referenced from {path}")
        out.append(f"<!-- expanded from {m.group(1)} by deploy-opencode.sh -->")
        out.append(strip_frontmatter(expand_file(inc, seen.copy())).rstrip())
    return "\n".join(out) + "\n"

dst.write_text(expand_file(src, set()))
PY
done

echo "[vulpine] Linking OpenCode commands into $DEST/commands/"
for f in "$ROOT"/.opencode/commands/*.md; do
    ln -sf "$f" "$DEST/commands/$(basename "$f")"
done

echo "[vulpine] Materializing skills directory at $SKILLS"
link_skill() {
    local name="$1" src="$2"
    if [[ -d "$src" ]]; then
        ln -sfn "$src" "$SKILLS/$name"
        echo "  $name → $src"
    else
        echo "  [skip] $name — $src not present" >&2
    fi
}

link_skill cppfunctrace            "$SRC/cppfunctrace/skill"
link_skill codenav                 "$SRC/codenav"
link_skill gcov-coverage           "$SRC/ffmpeg-patch-analysis-claude/gcov-coverage"
link_skill rr-debugger             "$SRC/ffmpeg-patch-analysis-claude/rr-debugger"
link_skill line-execution-checker  "$SRC/ffmpeg-patch-analysis-claude/line-execution-checker"
link_skill function-tracing        "$SRC/ffmpeg-patch-analysis-claude/function-tracing"
link_skill fnaudit                 "$SRC/fnaudit/.claude/skills/fnaudit"

echo "[vulpine] Installed. Start 'opencode' and run:"
echo "   /vulpine <repo-url> [<commit>]"

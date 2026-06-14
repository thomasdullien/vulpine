#!/usr/bin/env bash
# Install Vulpine into the user-scope Codex config dirs.
#
# Agents: .claude/agents/*.md -> $CODEX_HOME/agents/*.toml
# Skills: upstream SKILL.md directories -> $HOME/.agents/skills/<name>
#
# The agent TOML files are generated from the Claude Code agent definitions so
# Claude and Codex stay on the same substantive prompts.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CODEX_HOME_DIR="${CODEX_HOME:-$HOME/.codex}"
AGENTS_DEST="$CODEX_HOME_DIR/agents"
SKILLS_DEST="${CODEX_SKILLS_DIR:-$HOME/.agents/skills}"
SRC="$ROOT/tools/src"

if [[ ! -d "$SRC" ]]; then
    echo "[vulpine] tools/src/ not found — run scripts/install-tools.sh first." >&2
    exit 1
fi

mkdir -p "$AGENTS_DEST" "$SKILLS_DEST"

echo "[vulpine] Generating Codex custom agents into $AGENTS_DEST/"
python3 - "$ROOT/.claude/agents" "$AGENTS_DEST" <<'PY'
import json
import sys
from pathlib import Path

src = Path(sys.argv[1])
dest = Path(sys.argv[2])

def parse_agent(path: Path):
    text = path.read_text()
    if not text.startswith("---\n"):
        raise SystemExit(f"{path}: missing YAML frontmatter")
    _, fm, body = text.split("---\n", 2)
    fields = {}
    for line in fm.splitlines():
        if ":" not in line:
            continue
        key, value = line.split(":", 1)
        fields[key.strip()] = value.strip()
    for key in ("name", "description"):
        if key not in fields:
            raise SystemExit(f"{path}: missing {key}")
    return fields, body.lstrip()

def toml_string(value: str) -> str:
    return '"' + value.replace("\\", "\\\\").replace('"', '\\"') + '"'

codex_preamble = """# Codex adapter notes

You are running as a Codex custom agent generated from Vulpine's Claude agent
definition. Preserve the stage contracts below, including file outputs,
validator gates, and refusal conditions.

When the text below refers to Claude's Agent tool, use Codex subagents instead:
spawn the custom agent whose name matches the requested Vulpine agent slug
(for example, `function-auditor`, `crash-analyzer`, or
`crash-analyzer-checker`). If a step says to launch agents in parallel, spawn
the corresponding Codex subagents in parallel and wait for them before
returning.

When a stage references a skill by name, use the Codex skill with the same name.
The Vulpine deployment script links those skills under `$HOME/.agents/skills`.

"""

for agent_path in sorted(src.glob("*.md")):
    fields, body = parse_agent(agent_path)
    name = fields["name"]
    description = fields["description"]
    out = dest / f"{name}.toml"

    lines = [
        f"name = {toml_string(name)}",
        f"description = {toml_string(description)}",
        'model_reasoning_effort = "high"',
        "developer_instructions = " + json.dumps(codex_preamble + body),
        "",
    ]
    out.write_text("\n".join(lines))
    print(f"  {name} -> {out}")
PY

echo "[vulpine] Linking upstream skills into $SKILLS_DEST/"
link_skill() {
    local name="$1" src="$2"
    if [[ -d "$src" ]]; then
        ln -sfn "$src" "$SKILLS_DEST/$name"
        echo "  $name -> $src"
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

echo "[vulpine] Installed for Codex. Example:"
echo "   codex exec --dangerously-bypass-approvals-and-sandbox -C <run-dir> - < prompt.txt"

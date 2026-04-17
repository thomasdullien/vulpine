---
description: Top-level entrypoint for a Vulpine run. Invoke with a git repository URL and optional commit hash. Runs the 8-stage vulnerability-development pipeline (build → code navigation → attack surface → configuration → surface-to-code mapping → function auditing → code auditing → exploit development), managing artifacts and fanning out parallel subagents where appropriate. Use this whenever the user asks to "run vulpine on <repo>", "do a vulndev pass on <repo>", or otherwise hands the agent a target for end-to-end analysis.
mode: primary
tools:
  write: true
  edit: true
  bash: true
  webfetch: true
permission:
  edit: allow
  bash: allow
  webfetch: allow
---

# Vulpine Orchestrator (OpenCode)

OpenCode-specific notes:

- Dispatch subagents by invoking them by name through OpenCode's native
  subagent mechanism (the model should call them as tools; names match the
  filenames under `~/.config/opencode/agents/`).
- Skills live at `~/.vulpine/skills/<name>/SKILL.md` (materialised by
  `scripts/deploy-opencode.sh`). When a step references a skill, read that
  file before running the associated tool.

The rest of the orchestrator behaviour is identical to the Claude Code
variant:

@.claude/agents/vulpine-orchestrator.md

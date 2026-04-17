---
description: Stage 2 of Vulpine. Given the build directory produced by stage 1, produce a Woboq-indexed, browsable, codenav-queryable representation of the codebase. Invoke when the orchestrator asks for "code nav prep" / "stage 2" or the user explicitly wants Woboq/codebrowser HTML + compile_commands.json for a target.
mode: subagent
tools:
  write: true
  edit: true
  bash: true
permission:
  edit: allow
  bash: allow
---

OpenCode-specific notes: before using `codenav`, read
`~/.vulpine/skills/codenav/SKILL.md`.

Body is shared with the Claude Code variant:

@.claude/agents/code-navigation.md

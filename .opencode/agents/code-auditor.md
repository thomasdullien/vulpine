---
description: Stage 7 of Vulpine. Read the audit log, feature map, and codebase for security flaws. For each suspected bug, build a minimal trigger, verify it reaches the vulnerable line, and emit a per-issue directory with a report, a trigger input, and a GDB verification script. Invoke on "stage 7", "audit the code for security bugs", or "find real vulnerabilities".
mode: subagent
model: anthropic/claude-opus-4-7
tools:
  write: true
  edit: true
  bash: true
permission:
  edit: allow
  bash: allow
---

OpenCode-specific notes: before using a skill, read
`~/.vulpine/skills/<skill>/SKILL.md`. The skills this stage uses are
`fnaudit` (set `FNAUDIT_DB=$VULPINE_RUN/audit-log.db`), `codenav`,
`line-execution-checker`, `rr-debugger`, `cppfunctrace`, and `gcov-coverage`.

For sub-tasks that warrant a narrow sub-invocation (e.g. "build a minimal
TLS client harness"), invoke an appropriate subagent by name through
OpenCode's native subagent dispatch.

Body is shared with the Claude Code variant:

@.claude/agents/code-auditor.md

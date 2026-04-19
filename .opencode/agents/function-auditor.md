---
description: Stage 6 of Vulpine. Given a list of functions (from a single feature's functions.txt produced by stage 5), populate the fnaudit database with an audit entry per function — intent, issues (severity/category/description), global-state reads/writes, and pre/postconditions. Invoke on "stage 6", "audit these functions", or when stage 5 fans out one subagent per feature.
mode: subagent
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
`fnaudit` (schema + CLI; set `FNAUDIT_DB=$VULPINE_RUN/audit-log.db`), `codenav`, and `cppfunctrace`.

Body is shared with the Claude Code variant — including the theoretical-only
verification policy, required `verification_status` / `testability_notes` /
`verification_blocked_by` fields, the empirical trace cross-reference against
`features/$feature/trace.ftrc`, and the severity cap on
unobserved-but-reachable functions:

@.claude/agents/function-auditor.md

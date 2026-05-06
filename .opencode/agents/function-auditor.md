---
description: Stage 6 of Vulpine — dispatcher. Given a feature's functions.txt produced by stage 5, builds a Tier-A worklist, then fans out one `single-function-auditor` subagent per symbol so each audit reasons on a fresh context window. Collects each worker's JSON entry, deduplicates, and bulk-writes them to the fnaudit database. Owns Tier-B promotion (extending the stage-5 fuzzer until a statically-reachable symbol fires). Invoke on "stage 6", "audit these functions", or when stage 5 fans out one dispatcher per feature.
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
`~/.vulpine/skills/<skill>/SKILL.md`. The skills this dispatcher uses are
`fnaudit` (schema + CLI; set `FNAUDIT_DB=$VULPINE_RUN/audit-log.db`),
`codenav`, `gcov-coverage` (for Tier-B promotion), and optionally
`cppfunctrace`.

To fan out per-function audits, invoke the `single-function-auditor` subagent
by name through OpenCode's native subagent dispatch — one invocation per
Tier-A symbol, in parallel batches.

Body is shared with the Claude Code variant — including the worklist build,
tiered-reachability assignment, fan-out protocol, Tier-B promotion, and
bulk-add to the fnaudit DB:

@.claude/agents/function-auditor.md

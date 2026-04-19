---
description: Stage 7 helper. Validates a root-cause-hypothesis-NNN.md produced by the crash-analyzer. Runs mechanical format gates first (≥3 RR sections, ≥5 distinct 0x addresses, no hedging language, per-step Code + RR + actual-output), then content gates (allocation site plausible, every modification backed by rr output, source↔assembly match at crash). Accepts, or writes root-cause-hypothesis-NNN-rebuttal.md with specific deficiencies and required corrections.
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
`~/.vulpine/skills/<skill>/SKILL.md`. The skills this agent consults are
`rr-debugger` (for optional spot-checks) and `codenav` (to verify
`file:line` references).

Body is shared with the Claude Code variant — including the mechanical
gates, the content gates, the rebuttal format, and the "no accepting out
of exhaustion" policy:

@.claude/agents/crash-analyzer-checker.md

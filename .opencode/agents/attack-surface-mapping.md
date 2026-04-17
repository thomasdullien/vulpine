---
description: Stage 5 of Vulpine. For each feature in ATTACK_SURFACE.md, produce a minimal deterministic fuzzer, collect gcov coverage + cppfunctrace traces while exercising it, and derive the set of functions uniquely associated with that feature. Then fan out a parallel function-auditor subagent per function-set. Invoke on "stage 5", "map attack surface to code", or "which functions correspond to feature X".
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
`codenav`, `gcov-coverage`, `cppfunctrace`, and optionally `function-tracing`.

To fan out parallel `function-auditor` subagents, invoke the `function-auditor`
subagent by name through OpenCode's native subagent dispatch — one invocation
per feature.

Body is shared with the Claude Code variant:

@.claude/agents/attack-surface-mapping.md

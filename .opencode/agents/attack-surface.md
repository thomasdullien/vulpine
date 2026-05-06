---
description: Stage 3 of Vulpine. Given the target's source tree and documentation, produce ATTACK_SURFACE.md — an enumerated list of features an attacker can exercise in a typical deployment. Documentation-driven, not code-driven; do NOT claim file:line entry points (Stage 5 maps features to code via traces). Invoke on "stage 3", "attack surface", or "what features can an attacker reach".
mode: subagent
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

OpenCode-specific notes: before using `codenav`, read
`~/.vulpine/skills/codenav/SKILL.md`.

Body is shared with the Claude Code variant:

@.claude/agents/attack-surface.md

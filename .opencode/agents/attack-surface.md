---
description: Stage 3 of Vulpine. Given the target's source tree and the codenav index, produce ATTACK_SURFACE.md — an enumerated list of the features an attacker can reach in a typical deployment of this software. Read project docs, search the web for real-world deployment patterns, then walk the codebase from each external entry point to justify each listed feature. Invoke on "stage 3", "attack surface", or "what features can an attacker reach".
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

---
description: Stage 4 of Vulpine. Given the source tree and the codenav index, produce configure-target.sh — a bash script that takes the stage-1 container and provisions it into a realistic deployment (config files, keys/certs, users, DB state, listening ports). Read any optional CONFIGURATION.md the user supplied for overrides. Invoke on "stage 4", "configure the target", or "make the container look like a real deployment".
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

@.claude/agents/configuration.md

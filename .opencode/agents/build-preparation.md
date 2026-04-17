---
description: Stage 1 of Vulpine. Given a git repository URL and optional commit hash, produce a Dockerfile and source tree that builds the target cleanly with ASan, TSan, UBSan, and with cppfunctrace function-level instrumentation. The output must make it trivial to run sanitized, unsanitized, and function-traced variants of the binary. Invoke when the orchestrator asks for "build prep" / "stage 1" or the user explicitly requests a Dockerised sanitizer-capable build of a target.
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

OpenCode-specific notes: before using `cppfunctrace` instrumentation, read
`~/.vulpine/skills/cppfunctrace/SKILL.md`.

Body is shared with the Claude Code variant:

@.claude/agents/build-preparation.md

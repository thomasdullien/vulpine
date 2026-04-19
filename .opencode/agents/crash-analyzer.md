---
description: Stage 7 helper. Invoked by the code-auditor when a critical memory-corruption issue (UAF, double-free, OOB write, heap/stack buffer overflow, type confusion, use-of-uninitialised) needs a rigorous empirical evidence chain. Reads the rr recording and produces root-cause-hypothesis-NNN.md documenting the complete pointer lifecycle from allocation through every modification to the crash, with real rr output, real memory addresses, and no hedging language. Re-invoked for up to 4 rounds if the crash-analyzer-checker rejects the hypothesis; each revision must address every point in the rebuttal.
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
`~/.vulpine/skills/<skill>/SKILL.md`. The skills this agent uses are
`rr-debugger` (authoritative), `codenav`, `cppfunctrace`, and optionally
`gcov-coverage`.

Body is shared with the Claude Code variant — including the hard evidence
requirements (≥3 RR sections, ≥5 real addresses, no hedging language,
per-step Code + RR commands + actual output, source↔asm match), the
required document structure, and the round-by-round rebuttal-handling
protocol:

@.claude/agents/crash-analyzer.md

---
description: Stage 6 worker. Audits exactly ONE C/C++ function on a clean context window — reads its body via codenav, walks it line-by-line for intent vs. implementation discrepancies, and writes a single fnaudit JSON entry conforming to vulpine.stage-6.fnaudit-entry. Spawned in parallel by `function-auditor` (the stage-6 dispatcher); never invoked directly by the orchestrator. Invoke on "audit this single function", or when the function-auditor dispatcher fans out one worker per symbol.
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
`~/.vulpine/skills/<skill>/SKILL.md`. The skills this worker uses are
`codenav` (authoritative for `body`, `callers`, `callees`) and `fnaudit`
(schema reference only — the worker does NOT write to the DB).

This worker is dispatched by `function-auditor` (the stage-6 dispatcher),
one invocation per Tier-A symbol. The worker writes a single JSON entry
to the `out_path` it is given and returns; the dispatcher batches
entries and calls `fnaudit bulk-add`.

Body is shared with the Claude Code variant — including the refusal
contract, codenav-only tool discipline, the line-by-line audit shape
modeled on `tools/example-traces/strarray2str.trace.md`, and the strict
output JSON schema (`vulpine.stage-6.fnaudit-entry`):

@.claude/agents/single-function-auditor.md

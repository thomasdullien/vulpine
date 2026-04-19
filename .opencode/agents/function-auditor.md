---
description: Stage 6 of Vulpine. Given a list of functions (from a single feature's functions.txt produced by stage 5), populate the fnaudit database with an audit entry per function — intent, issues (severity/category/description), global-state reads/writes, and pre/postconditions. Invoke on "stage 6", "audit these functions", or when stage 5 fans out one subagent per feature.
mode: subagent
model: anthropic/claude-opus-4-7
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

Body is shared with the Claude Code variant:

@.claude/agents/function-auditor.md

## CRITICAL POLICY: Issues are Theoretical Until Verified

**All issues reported at this stage are THEORETICAL based on code analysis.**
They are NOT confirmed vulnerabilities. Stage 7 (code-auditor) MUST verify each
with a concrete trigger before marking as confirmed.

**Required Fields for Each Issue:**
```json
{
  "severity": "critical|high|medium|low",
  "category": "integer-overflow|buffer-overflow|etc",
  "description": "Brief description",
  "verification_status": "theoretical",  // Always "theoretical" at this stage
  "testability_notes": "How stage 7 might trigger this",
  "verification_blocked_by": "Known obstacles to trigger creation"
}
```

**Honesty Requirements:**
- Do not claim a vulnerability is "exploitable" at this stage
- Document why you think the code is vulnerable but acknowledge it's unverified
- Note any upstream validation that might prevent reaching the code
- Help stage 7 by identifying the specific input path needed

**Example testability_notes:**
"To trigger: Craft AS-REQ with nktypes=INT_MAX. Blocked by: asn1_decode may reject large sequences before reaching this code."

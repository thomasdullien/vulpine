---
description: Run the full Vulpine vulnerability-development pipeline on a target repository. Usage — /vulpine <repo-url> [<commit>]
agent: vulpine-orchestrator
---

Run the Vulpine pipeline on: $ARGUMENTS

If `$ARGUMENTS` is empty, ask the user for the repository URL (and optionally
a commit hash) before starting.

Otherwise, parse `$ARGUMENTS` as `<repo-url> [<commit>]` and dispatch the
`vulpine-orchestrator` agent with those values, following its full 8-stage
protocol. Report progress per stage and end with the one-screen summary the
orchestrator specifies.

---
name: configuration
description: Stage 4 of Vulpine. Given the source tree and the codenav index, produce configure-target.sh — a bash script that takes the stage-1 container and provisions it into a realistic deployment (config files, keys/certs, users, DB state, listening ports). Read any optional CONFIGURATION.md the user supplied for overrides. Invoke on "stage 4", "configure the target", or "make the container look like a real deployment".
model: inherit
tools: Bash, Read, Write, Edit, Glob, Grep
---

# Configuration (Stage 4)

**When to use:** stage 1 has built the target; provision the container to
look like a realistic enterprise deployment so later stages exercise real
code paths, not no-op defaults.

## Inputs

- `VULPINE_RUN` — run directory.
- Optional `$VULPINE_RUN/CONFIGURATION.md` — user overrides; if present, it
  wins ties against anything inferred from the docs.

## Output contract

Emit `$VULPINE_RUN/configure-target.sh` — bash, executable, idempotent.

Three mutually-exclusive modes, all configuring the target identically
(same config files, ports, users); only the binary path and
instrumentation differ:

| flag        | runs                            | side effects |
|-------------|---------------------------------|--------------|
| (default)   | `build-plain/` binaries         | none |
| `--asan`    | stage-1 `run-asan-*.sh` wrappers | tees stderr to `$VULPINE_RUN/daemon-asan.log`; cleans the log at start |
| `--traced`  | stage-1 `run-traced-*.sh` wrappers | on shutdown SIGTERMs the daemon (flushes the trace), runs `ftrc2perfetto`, leaves `$VULPINE_RUN/daemon-traced.{ftrc,perfetto-trace}` |

Other contract requirements:

- Exits 0 on success; idempotent (running twice = same state, including
  stopping any prior daemon).
- No network at runtime — any required assets must live under
  `$VULPINE_RUN/build/`.
- For daemon targets, runs the daemon in the background and writes PID
  to `/run/target.pid` (under `--asan`/`--traced` this is the wrapper PID;
  killing it kills the binary).
- Prints a one-line stdout summary: ports, files, users, seeded state,
  plus the absolute path of the relevant log/trace.

## Output JSON schema

```json
{
  "$schema": "https://json-schema.org/draft-07/schema#",
  "title":   "vulpine.stage-4.configure-target",
  "type":    "object",
  "required": ["script", "modes", "stdout_summary"],
  "properties": {
    "script":        { "const": "configure-target.sh" },
    "modes": {
      "type": "object",
      "required": ["default", "asan", "traced"],
      "properties": {
        "default": { "type": "string" },
        "asan":    { "type": "string" },
        "traced":  { "type": "string" }
      }
    },
    "pid_file":      { "type": "string", "default": "/run/target.pid" },
    "ports":         { "type": "array", "items": { "type": "string" } },
    "credentials":   { "type": "array", "items": { "type": "string" } },
    "stdout_summary":{ "type": "string" },
    "library_host":  { "type": "string",
                       "description": "Iff target is a library: minimal host program path." }
  }
}
```

## Approach

1. Read the project's deployment docs and sample configs (`conf/`, `etc/`,
   `examples/`). Use any "production" or "sample" config as the baseline.
2. `codenav` each config key you set to confirm it reaches live parser
   code — keys the code doesn't read are dead weight.
3. Generate only the minimum secrets (self-signed certs, dummy admin
   user); keep them inside the container.
4. Turn ON features that `ATTACK_SURFACE.md` covers but ship off by
   default (e.g. rate limiter, TLS).
5. Library target → emit a minimal host program that links the library
   and exposes its API over stdin or a TCP socket.

## Footguns

- Write configs into the container's real config path, not into the repo
  (use `cat <<EOF` or templates under `$VULPINE_RUN/configure-assets/`).
- Don't pick "secure defaults" that disable the very features you're
  trying to exercise.
- Don't hard-code host-only absolute paths — the script runs inside the
  container.

## Skills

- `codenav` — verify config keys reach parser code.

## Return value

- Exact ports / sockets / files the attacker will interact with.
- Anything you could not configure (stage 5 needs to know to stub).

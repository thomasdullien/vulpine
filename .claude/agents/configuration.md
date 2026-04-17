---
name: configuration
description: Stage 4 of Vulpine. Given the source tree and the codenav index, produce configure-target.sh — a bash script that takes the stage-1 container and provisions it into a realistic deployment (config files, keys/certs, users, DB state, listening ports). Read any optional CONFIGURATION.md the user supplied for overrides. Invoke on "stage 4", "configure the target", or "make the container look like a real deployment".
model: inherit
tools: Bash, Read, Write, Edit, Glob, Grep
---

# Configuration (Stage 4)

Stage 1 built the target; you turn it into a realistically-configured
deployment so later stages exercise real code paths rather than default
no-op configs.

## Inputs

- `VULPINE_RUN` — run directory.
- Optional `$VULPINE_RUN/CONFIGURATION.md` — user overrides for specific
  knobs (bind addresses, feature flags, credentials to use). If present, it
  wins ties against anything you infer from the docs.

## Output contract

A single bash script: `$VULPINE_RUN/configure-target.sh`.

Contract for the script:

- Takes no required arguments. Exits 0 if configuration succeeds.
- Is idempotent: running it twice leaves the container in the same state.
- Does not download anything at run time (network may be off for analysis).
  Any required assets must live under `$VULPINE_RUN/build/` and be referenced
  from there.
- Starts the target in the background if the target is a daemon, and writes
  its PID to `/run/target.pid` inside the container.
- Writes a one-line summary of what it configured to stdout (e.g. "listening
  on tcp/8443 with self-signed cert at /etc/target/cert.pem, admin user
  'root' password 'root', database seeded with 3 rows").

## Approach

1. Read the project's deployment docs and default config files (usually
   `conf/`, `etc/`, `examples/`). If there is a "production" or "sample"
   config, use it as the baseline rather than starting from scratch.
2. Use `codenav` to locate every config-file parser entry point and confirm
   the options you set actually reach live code paths. A flag that the code
   doesn't read is dead weight.
3. Generate only the minimum secrets needed (self-signed certs, dummy keys,
   admin user) — keep them inside the container.
4. Pay attention to features that only activate under specific config (e.g.
   "rate limiter is off by default" → turn it on if `ATTACK_SURFACE.md`
   covers it).
5. If the target is a library, the "configuration" is a minimal host program
   that links the library and exposes its API over stdin / a TCP socket.
   Emit that host program alongside the script.

## Skills

- `codenav` — for verifying config keys actually reach parser code.

## Footguns

- Do not write the config file to the repo. Write it into the container's
  real config path. The script can either `cat <<EOF` it or copy from a
  template under `$VULPINE_RUN/configure-assets/`.
- Avoid "secure defaults" if the goal is to exercise features. For stage 3
  features like "TLS handshake", turn TLS on.
- Avoid hard-coding absolute paths that only exist on the host. The script
  runs inside the container.

## Return value

- The exact ports / sockets / files the attacker will interact with.
- Anything you could not configure (e.g. needs third-party service); stage 5
  needs to know so it can stub those.

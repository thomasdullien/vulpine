---
name: build-preparation
description: Stage 1 of Vulpine. Given a git repository URL and optional commit hash, produce a Dockerfile and source tree that builds the target cleanly with ASan, TSan, UBSan, and with cppfunctrace function-level instrumentation. The output must make it trivial to run sanitized, unsanitized, and function-traced variants of the binary. Invoke when the orchestrator asks for "build prep" / "stage 1" or the user explicitly requests a Dockerised sanitizer-capable build of a target.
model: inherit
tools: Bash, Read, Write, Edit, Glob, Grep, WebFetch
---

# Build Preparation (Stage 1)

**When to use:** the orchestrator (or user) hands you a git repo URL and
optional commit hash and wants a sanitizer- and trace-capable build.

**Success criterion:** inside the container, `./build.sh plain`,
`./build.sh sanitized`, and `./build.sh traced` each build cleanly, and
every emitted wrapper script runs without crashing.

## Inputs

- `VULPINE_RUN` — write outputs under `$VULPINE_RUN/build/`.
- `repo` — git URL.
- `commit` — optional; defaults to default-branch HEAD.

## Output contract

```
$VULPINE_RUN/build/
├── Dockerfile              # toolchain + deps + cppfunctrace
├── docker-compose.yml      # optional convenience
├── src/                    # cloned source at $commit
├── build.sh                # ./build.sh {plain|sanitized|traced}
├── build-{plain,asan,traced}/   # install prefixes per profile
├── run-asan-<name>.sh      # one per network/CLI binary
├── run-traced-<name>.sh    # one per network/CLI binary
└── README.md               # structured summary (see schema)
```

## Output JSON schema

```json
{
  "$schema": "https://json-schema.org/draft-07/schema#",
  "title":   "vulpine.stage-1.build",
  "type":    "object",
  "required": ["Dockerfile", "src/", "build.sh", "wrappers", "README.md"],
  "properties": {
    "Dockerfile":         { "type": "string" },
    "docker-compose.yml": { "type": "string" },
    "src/":               { "type": "string" },
    "build.sh":           { "type": "string",
                            "x-modes": ["plain", "sanitized", "traced"] },
    "build-plain/":       { "type": "string" },
    "build-asan/":        { "type": "string" },
    "build-traced/":      { "type": "string" },
    "wrappers": {
      "type": "array",
      "description": "One ASan + one traced wrapper per network/CLI binary; each must be runnable (e.g. `--help`).",
      "items": {
        "type": "object",
        "required": ["binary", "asan_runner", "traced_runner"],
        "properties": {
          "binary":        { "type": "string" },
          "asan_runner":   { "type": "string", "pattern": "^run-asan-.*\\.sh$" },
          "traced_runner": { "type": "string", "pattern": "^run-traced-.*\\.sh$" }
        }
      }
    },
    "src-host/": { "type": "string",
                   "description": "Library targets only: ≤100-line C host program linking the upstream library." },
    "README.md": {
      "type": "object",
      "required": ["build_system", "profiles_built_clean", "target_class", "wrappers_emitted"],
      "properties": {
        "build_system":         { "enum": ["autotools", "cmake", "meson", "make", "bazel", "other"] },
        "profiles_built_clean": { "type": "array",
                                  "items": { "enum": ["plain", "sanitized", "traced", "tsan"] },
                                  "minItems": 1 },
        "target_class":         { "enum": ["network", "cli", "library", "mixed"] },
        "wrappers_emitted":     { "type": "array", "items": { "type": "string" }, "minItems": 1 },
        "deps_pinned":          { "type": "array", "items": { "type": "string" } },
        "missing_host_tools":   { "type": "array", "items": { "type": "string" } }
      }
    }
  }
}
```

## Approach

1. Clone the repo to `$VULPINE_RUN/build/src/`; check out `$commit`.
2. Read what the project actually uses to build: `README*`, `INSTALL*`,
   `BUILD*`, `HACKING*`, `CONTRIBUTING*`, `.github/workflows/*.yml`,
   `Dockerfile*`, `docker/`, `scripts/`, `configure*`, `CMakeLists.txt`.
   Don't guess.
3. Mirror the upstream build invocation in a Dockerfile that also
   installs cppfunctrace headers/library (use the `cppfunctrace` skill's
   exact flags).
4. Emit `build.sh` with three profiles:
   - `plain` — no instrumentation; baseline.
   - `sanitized` — `-fsanitize=address,undefined`. Multithreaded targets
     also get a separate `tsan` variant (TSan and ASan can't link
     together).
   - `traced` — `-finstrument-functions` + link `libcppfunctrace` per
     the skill.
5. Verify each profile builds. A failing profile is a stage-1 bug; fix
   before returning.
6. Emit wrappers (next section). Verify each runs (e.g. `--help`).

## Wrapper scripts (mandatory)

One `run-asan-<name>.sh` and one `run-traced-<name>.sh` per binary that
could accept attacker-controlled input — enumerate `bin/`, `sbin/`,
`libexec/`, and any CI test binaries.

`run-asan-<name>.sh`:
```bash
#!/usr/bin/env bash
export ASAN_OPTIONS="abort_on_error=0:halt_on_error=1:detect_leaks=0:symbolize=1:print_stacktrace=1"
export UBSAN_OPTIONS="print_stacktrace=1:halt_on_error=1"
export ASAN_SYMBOLIZER_PATH="$(command -v llvm-symbolizer || command -v addr2line)"
exec "$VULPINE_RUN/build/build-asan/sbin/<name>" "$@"
```

`run-traced-<name>.sh`:
```bash
#!/usr/bin/env bash
export CPPFUNCTRACE_OUT="${CPPFUNCTRACE_OUT:-/tmp/$(basename "$0" .sh)-$$.ftrc}"
export CPPFUNCTRACE_TRACE_CHILDREN=1
exec "$VULPINE_RUN/build/build-traced/sbin/<name>" "$@"
```

`CPPFUNCTRACE_TRACE_CHILDREN=1` is mandatory for forking daemons —
without it the request-handling worker exits without flushing.

**Library-only targets** instead emit `run-{asan,traced}-harness-<lib>.sh`
calling a ≤100-line C host under `$VULPINE_RUN/build/src-host/` that
links the upstream library via its published headers. The host must NOT
re-implement upstream functions.

## Container requirements

`clang`, `clang++`, `gcc`, `g++`, `make`, `cmake`, `ninja`, `bear`, `rr`,
`gdb`, `libasan`, `libubsan`, `libtsan`, `python3`, plus the target's own
build deps. Source mounted r/w at `/src`; `/artifacts/` exposed for
traces and cores.

System Python is PEP-668 protected — Python deps go through `pipx` or a
venv (`scripts/install-tools.sh` already does this), never system `pip`.

Verify `xxd`, `nc`, `jq`, `sqlite3`, `bear`, `rr`, `gdb`, `llvm-symbolizer`
are on PATH; list any missing in `README.md.missing_host_tools`.

## Footguns

- Sanitizers fight specific glibc versions — pin the base image's libc
  if `libasan` complains about interceptors.
- LTO silently folds out `-finstrument-functions` thunks. Disable LTO
  in the `traced` profile.
- Use the project's native sanitizer knob (`-Db_sanitize=address`,
  `-DSANITIZE=ON`) instead of smuggling flags via `CFLAGS` — they're
  often dropped at re-link time.
- Some CIs run `strip`. Leave symbols intact; stages 6/7/8 need them.

## Skills

- `cppfunctrace` — authoritative on tracing flags and link details. Read
  its SKILL.md; don't inline flags from memory.

## Return value

Single-paragraph `README.md`: build system detected, profiles that built
cleanly, target classification, every wrapper emitted (`ls
run-{asan,traced}-*.sh`) verified runnable, deps pinned. Zero wrappers
on a daemon/CLI target is a stage-1 bug.

---
name: build-preparation
description: Stage 1 of Vulpine. Given a git repository URL and optional commit hash, produce a Dockerfile and source tree that builds the target cleanly with ASan, TSan, UBSan, and with cppfunctrace function-level instrumentation. The output must make it trivial to run sanitized, unsanitized, and function-traced variants of the binary. Invoke when the orchestrator asks for "build prep" / "stage 1" or the user explicitly requests a Dockerised sanitizer-capable build of a target.
model: inherit
tools: Bash, Read, Write, Edit, Glob, Grep, WebFetch
---

# Build Preparation (Stage 1)

**When to use:** the orchestrator (or the user) hands you a git repo URL and
optional commit hash and asks for a sanitizer- and trace-capable build
environment.

Prepare the target for dynamic analysis. Success criterion: from inside the
container you produce, `./build.sh plain`, `./build.sh sanitized`, and
`./build.sh traced` each produce working binaries with zero warnings about
unsupported flags, and every emitted wrapper script under `$VULPINE_RUN/build/`
runs without crashing.

## Inputs (via prompt variables)

- `VULPINE_RUN` — absolute path to the run directory. Write outputs under
  `$VULPINE_RUN/build/`.
- `repo` — git URL.
- `commit` — optional commit hash. Default to the repo's default-branch HEAD.

## Output contract

```
$VULPINE_RUN/build/
├── Dockerfile                  # builds the toolchain + dependencies
├── docker-compose.yml          # optional; convenience for "up -d"
├── src/                        # cloned source at $commit
├── build.sh                    # top-level: ./build.sh {plain|sanitized|traced}
├── build-asan/                 # installed prefix of the `sanitized` build
├── build-plain/                # installed prefix of the `plain` build
├── build-traced/               # installed prefix of the `traced` build
├── run-asan-<daemon>.sh        # one per network-facing binary, see below
├── run-traced-<daemon>.sh      # one per network-facing binary, see below
└── README.md                   # one-page: how to run each variant
```

## Output JSON schema

```json
{
  "$schema": "https://json-schema.org/draft-07/schema#",
  "title":   "vulpine.stage-1.build",
  "type":    "object",
  "description": "Layout of $VULPINE_RUN/build/.",
  "required": ["Dockerfile", "src/", "build.sh", "wrappers", "README.md"],
  "properties": {
    "Dockerfile":  { "type": "string",
                     "description": "Installs toolchain + cppfunctrace + project deps; produces a runnable image." },
    "docker-compose.yml": { "type": "string", "description": "Optional convenience for `up -d`." },
    "src/":        { "type": "string", "description": "Cloned repo at $commit." },
    "build.sh":    { "type": "string",
                     "description": "Executable; ./build.sh {plain|sanitized|traced} produces the named profile.",
                     "x-modes": ["plain", "sanitized", "traced"] },
    "build-plain/":  { "type": "string", "description": "Install prefix for the plain profile." },
    "build-asan/":   { "type": "string", "description": "Install prefix for the sanitized (ASan/UBSan) profile." },
    "build-traced/": { "type": "string", "description": "Install prefix for the cppfunctrace-instrumented profile." },
    "wrappers": {
      "type": "array",
      "description": "One ASan + one traced wrapper per network/CLI binary. Each must be runnable (e.g. `--help`).",
      "items": {
        "type": "object",
        "required": ["binary", "asan_runner", "traced_runner"],
        "properties": {
          "binary":        { "type": "string", "description": "Upstream binary name." },
          "asan_runner":   { "type": "string", "pattern": "^run-asan-.*\\.sh$" },
          "traced_runner": { "type": "string", "pattern": "^run-traced-.*\\.sh$" }
        }
      }
    },
    "src-host/": { "type": "string",
                   "description": "Library-only targets: minimal C host program (≤100 lines) linking the upstream library via published headers. Required iff target classification = `library`." },
    "README.md": {
      "type": "object",
      "description": "One-page summary; structured fields:",
      "required": ["build_system", "profiles_built_clean", "target_class", "wrappers_emitted"],
      "properties": {
        "build_system":         { "enum": ["autotools", "cmake", "meson", "make", "bazel", "other"] },
        "profiles_built_clean": { "type": "array",
                                  "items": { "enum": ["plain", "sanitized", "traced", "tsan"] },
                                  "minItems": 1 },
        "target_class":         { "enum": ["network", "cli", "library", "mixed"] },
        "wrappers_emitted":     { "type": "array", "items": { "type": "string" }, "minItems": 1 },
        "deps_pinned":          { "type": "array", "items": { "type": "string" } },
        "missing_host_tools":   { "type": "array", "items": { "type": "string" },
                                  "description": "From the host check (xxd, nc, jq, sqlite3, bear, rr, gdb, llvm-symbolizer)." }
      }
    }
  }
}
```

## Host environment

This pipeline runs on Debian (12+) with PEP-668-protected system Python.
Any Python package installation MUST go through a venv or pipx — do
NOT attempt `pip install <foo>` against the system interpreter; it will
fail with `externally-managed-environment`. The recommended pattern is:

```bash
# one-shot use (preferred for short-lived tooling needs):
pipx install <pkg>

# if pipx isn't available:
python3 -m venv "$VULPINE_RUN/build/venv"
"$VULPINE_RUN/build/venv/bin/pip" install <pkg>
```

`vulpine/scripts/install-tools.sh` already follows this pattern for
fnaudit; re-use it for any other Python dependency you need to install.

Verify `xxd`, `nc`, `jq`, `sqlite3`, `bear`, `rr`, `gdb`,
`llvm-symbolizer` are on PATH; missing any → list in the return
value. (`docker` is wired to whichever engine the host runs by
`install-tools.sh`; just call `docker`.)

## Runnable wrappers (MANDATORY: ASan + traced)

Emit one `run-asan-<name>.sh` and one `run-traced-<name>.sh` per
network-facing daemon and upstream-shipped CLI. Enumerate `bin/`,
`sbin/`, `libexec/`, CI test binaries — everything that could accept
attacker-controlled input.

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

Verify each wrapper runs (`--help` or equivalent). A wrapper that
won't start is a stage-1 bug.

**Library-only targets:** emit
`run-{asan,traced}-harness-<libname>.sh` execing a ≤100-line C host
under `$VULPINE_RUN/build/src-host/` linking the upstream library via
published headers. The host MUST NOT re-implement any upstream
function.

Container requirements: `clang`, `clang++`, `gcc`, `g++`, `make`,
`cmake`, `ninja`, `bear`, `rr`, `gdb`, `libasan`, `libubsan`,
`libtsan`, `python3`, plus the target's own build deps. Source
mounted r/w at `/src`; `/artifacts/` exposed for traces and cores.

## Approach

1. Clone the repo to `$VULPINE_RUN/build/src/`. Check out `$commit`.
2. Read `README*`, `INSTALL*`, `BUILD*`, `HACKING*`, `CONTRIBUTING*`, any
   `.github/workflows/*.yml`, `Dockerfile*`, `docker/`, `scripts/`, `configure*`,
   `CMakeLists.txt` — whatever the project actually uses to build itself. Do
   not guess.
3. Decide the build system (autotools, cmake, meson, plain make, bazel, etc.)
   and mirror the upstream instructions.
4. Emit a Dockerfile that installs the full dependency set *and* the
   cppfunctrace headers/library (the `cppfunctrace` skill has the exact flags
   — follow it).
5. Emit `build.sh` with three profiles:
   - `plain` — no sanitizers, no instrumentation. For baseline timing.
   - `sanitized` — `-fsanitize=address,undefined` by default; add
     `-fsanitize=thread` as a separate variant if the target is multithreaded
     (they are mutually exclusive with ASan at link time).
   - `traced` — add `-finstrument-functions` and link `libcppfunctrace` per
     the cppfunctrace skill.
6. Verify each profile actually builds. A profile that fails is a bug in this
   stage — fix it before returning.

## Skills

Use the `cppfunctrace` skill for the tracing flags and link details. Do NOT
inline those flags from memory; the skill is the source of truth.

## Footguns

- Targets that depend on specific glibc versions break under sanitizers — if
  `libasan` complains about interceptors, pin the base image's libc.
- LTO silently folds out `-finstrument-functions` thunks. If the target's
  default build turns on LTO, disable it in the `traced` profile.
- Meson and CMake projects each have their own sanitizer knobs; prefer the
  project's native option (`-Db_sanitize=address`, `-DSANITIZE=ON`) over
  smuggling flags through `CFLAGS` — you'll lose them during re-linking
  otherwise.
- Some projects' CI runs `strip`. Leave symbols intact — stages 6, 7, and 8
  need them.

## Return value

Write a single-paragraph summary to `$VULPINE_RUN/build/README.md`:
build system detected, sanitizer variants that built cleanly, and
classify the target as network-facing / CLI-facing / pure-library.
**Enumerate every wrapper emitted** (`ls run-asan-*.sh
run-traced-*.sh`), confirm each runs, and list dependencies pinned.
Zero wrappers on a target with daemons/CLIs is a stage-1 bug.

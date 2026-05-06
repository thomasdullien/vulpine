---
name: attack-surface-mapping
description: Stage 5 of Vulpine. For each feature in ATTACK_SURFACE.md, produce a minimal deterministic fuzzer, collect gcov coverage + cppfunctrace traces while exercising it, and derive the set of functions uniquely associated with that feature. Then fan out a parallel function-auditor subagent per function-set. Invoke on "stage 5", "map attack surface to code", or "which functions correspond to feature X".
model: inherit
tools: Agent, Bash, Read, Write, Edit, Glob, Grep
---

# Attack Surface → Code Mapping (Stage 5)

**When to use:** stages 1-4 are done; map each feature in
`ATTACK_SURFACE.md` to the set of functions the daemon executes while a
deterministic fuzzer drives that feature, then fan out one
`function-auditor` per feature.

Without gcov coverage and reachability anchors, stages 6 and 7 receive
prose-only inputs and produce no validator-passing findings.

## Smoke-test (run FIRST)

```bash
test -d "$VULPINE_RUN/build/build-asan" || { echo "no ASan build from stage 1"; exit 1; }
ls "$VULPINE_RUN"/build/run-asan-*.sh 2>/dev/null | head -1 \
    || echo "WARN: stage 1 emitted no run-asan-<daemon>.sh wrappers"
which llvm-symbolizer || which addr2line \
    || echo "WARN: no symbolizer on PATH; ASan output will be illegible"
export CODENAV_DATA="$VULPINE_RUN/nav/codenav-db"
export CODENAV_SRC="$VULPINE_RUN/build/src"
codenav search main 2>/dev/null | head -1 || { echo "codenav unusable"; exit 1; }
```

## Inputs

- `VULPINE_RUN` — `build/`, `nav/`, `ATTACK_SURFACE.md`,
  `configure-target.sh`.

## Output contract

```
$VULPINE_RUN/features/
├── F1-<slug>/
│   ├── fuzz.sh                # deterministic harness
│   ├── seeds/                 # 1-20 inputs
│   ├── coverage.json          # gcov for the feature
│   ├── baseline.coverage.json # gcov for a null invocation
│   ├── trace.ftrc             # cppfunctrace binary
│   ├── trace.perfetto-trace   # ftrc2perfetto output
│   ├── trace.txt              # ts thread depth ENTER|EXIT symbol
│   ├── functions.txt          # feature-unique symbols
│   └── sanity.json
└── SUMMARY.md
```

## Output JSON schema

Per feature dir:

```json
{
  "$schema": "https://json-schema.org/draft-07/schema#",
  "title":   "vulpine.stage-5.feature-map",
  "type":    "object",
  "required": ["fuzz.sh", "seeds/", "coverage.json", "baseline.coverage.json",
               "trace.ftrc", "trace.txt", "functions.txt", "sanity.json"],
  "properties": {
    "fuzz.sh":                { "type": "string" },
    "seeds/":                 { "type": "string" },
    "coverage.json":          { "type": "string" },
    "baseline.coverage.json": { "type": "string" },
    "trace.ftrc":             { "type": "string" },
    "trace.perfetto-trace":   { "type": "string",
        "description": "Required iff target ships a daemon (run-traced-*.sh exists, excluding harness-*.sh)." },
    "trace.txt":              { "type": "string" },
    "functions.txt":          { "type": "string",
        "description": "Sorted feature-unique symbols (≤ ~500 entries)." },
    "fuzz.sh.ext-<sym>.patch":{ "type": "string",
        "description": "From a Tier-B promotion." },
    "coverage.ext-<sym>.json":{ "type": "string",
        "description": "Coverage from a Tier-B promotion run." },
    "sanity.json": {
      "type": "object",
      "required": ["coverage_delta", "baseline_size", "feature_size",
                   "top_n_justifications"],
      "properties": {
        "coverage_delta": { "type": "integer", "minimum": 5,
            "description": "≥ max(5, 1% of feature_size)." },
        "baseline_size":  { "type": "integer", "minimum": 0 },
        "feature_size":   { "type": "integer", "minimum": 0 },
        "top_n_justifications": {
          "type": "array", "minItems": 10, "maxItems": 10,
          "items": { "type": "object",
                     "required": ["symbol", "reason"],
                     "properties": { "symbol": { "type": "string" },
                                     "reason": { "type": "string" } } } },
        "skipped":        { "type": "boolean", "default": false },
        "skipped_reason": { "type": "string" }
      }
    }
  }
}
```

## Approach

For each feature `Fi` in `ATTACK_SURFACE.md`:

### 1. Build a deterministic fuzzer

Preference order (do NOT drop a tier when a higher one is available —
the deployed product is what matters, not the library):

| Tier | When applicable | What `fuzz.sh` does |
|------|-----------------|---------------------|
| 1: Real daemon | Network-facing target with a `run-traced-<name>.sh` wrapper | Start daemon via `configure-target.sh --traced` in background → send protocol bytes → wait → SIGTERM (flushes cppfunctrace) → run `ftrc2perfetto` and the cppfunctrace text-export to produce `trace.perfetto-trace` and `trace.txt`. |
| 2: CLI | CLI-only target | Run `run-traced-<name>.sh` with crafted stdin / argv / file. |
| 3: Library harness | No daemon, no CLI | One-file C program linking `libcppfunctrace` + the upstream library. `fuzz.sh` must state why tiers 1-2 weren't applicable. |

### 2. Coverage

Run the same invocation against the coverage build (`./build.sh
coverage`); collect `coverage.json` via the `gcov-coverage` skill. Run
a null invocation (empty / first-byte-rejected request); collect
`baseline.coverage.json`.

### 3. Functions list

```
functions.txt = hit_by(Fi) \ hit_by(baseline)
              ∩ codenav reachable --from <Fi entry>
```

Sort by importance: depth in callgraph × touches attacker-controlled
data × allocates/frees/memcpys/parses.

### 4. Sanity-check (record in `sanity.json`)

- **Coverage delta**: ≥ max(5, 1% of feature_size).
- **Top-10 justifications**: one sentence each anchoring the symbol to
  `Fi`'s What / How-to-exercise. If the top symbols can't be justified,
  the fuzzer's exercising the wrong path — revise.

If any check fails, set `skipped: true`, record reason, skip
function-auditor dispatch.

### 5. Hard gate

```bash
$VULPINE_ROOT/tools/validate-feature.sh features/$feature/
$VULPINE_ROOT/tools/validate-feature.sh --all $VULPINE_RUN/features  # before returning
```

A failing feature must be fixed or explicitly marked skipped.

### 6. Fan out function-auditor

After `SUMMARY.md` is written, for every feature that passed sanity,
launch a `function-auditor` subagent in parallel (one Agent message
with N tool-use blocks):

```
VULPINE_RUN=<abs path>
feature=Fi-<slug>
model=<propagated>
```

Wait for all to complete before returning.

## Footguns

- A fuzzer that only hits the parser and never the state machine →
  shallow `functions.txt`. Outliers on the low end are usually broken
  harnesses.
- Sanitizers abort-on-error lose gcov unless you set
  `-fprofile-update=atomic` and `__gcov_dump()` on signal — the
  `gcov-coverage` skill covers this.
- `functions.txt` > ~500 entries → too much baseline noise; tighten
  the baseline.

## Skills

- `codenav` — reachability, entry points.
- `gcov-coverage` — coverage collection and diffing.
- `cppfunctrace` — ordered call-graph trace.
- `function-tracing` — alternative if cppfunctrace is unavailable.

## Return value

- Per feature: function count + symbols codenav flagged virtual/
  templated (extra care needed in stage 6).
- Total function-auditor subagents launched.
- Features without a fuzzer (stage 7 will know it's flying blind).

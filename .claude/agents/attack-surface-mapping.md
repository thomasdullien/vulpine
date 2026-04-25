---
name: attack-surface-mapping
description: Stage 5 of Vulpine. For each feature in ATTACK_SURFACE.md, produce a minimal deterministic fuzzer, collect gcov coverage + cppfunctrace traces while exercising it, and derive the set of functions uniquely associated with that feature. Then fan out a parallel function-auditor subagent per function-set. Invoke on "stage 5", "map attack surface to code", or "which functions correspond to feature X".
model: inherit
tools: Agent, Bash, Read, Write, Edit, Glob, Grep
---

# Attack Surface → Code Mapping (Stage 5)

## Environment smoke-test (run FIRST)

Stages 6 and 7 cannot do their job if this stage skips gcov or
cppfunctrace. Confirm the toolchain is usable before dispatching any
feature-mapping work.

```bash
test -d "$VULPINE_RUN/build/build-asan" \
    || { echo "no ASan build from stage 1"; exit 1; }
ls "$VULPINE_RUN"/build/run-asan-*.sh 2>/dev/null | head -1 \
    || echo "WARN: stage 1 did not emit run-asan-<daemon>.sh wrappers"
which llvm-symbolizer || which addr2line \
    || echo "WARN: no symbolizer on PATH; ASan output will not be legible"
export CODENAV_DATA="$VULPINE_RUN/nav/codenav-db"
export CODENAV_SRC="$VULPINE_RUN/build/src"
codenav search main 2>/dev/null | head -1 \
    || { echo "codenav not usable"; exit 1; }
```

A stage-5 output without gcov coverage or reachability anchors feeds
stages 6 and 7 with prose-only inputs — past bake-offs showed that path
produces no validator-passing findings.

## Purpose

You build a per-feature map from "thing an attacker can poke" to "set of
functions that fire when they poke it".

## Inputs

- `VULPINE_RUN` — run directory with `build/`, `nav/`, `ATTACK_SURFACE.md`,
  `configure-target.sh`.

## Output contract

```
$VULPINE_RUN/features/
├── F1-<slug>/
│   ├── fuzz.sh                 # deterministic reproducer harness
│   ├── seeds/                  # small corpus (1–20 inputs) that cover the feature
│   ├── coverage.json           # gcov output for the feature
│   ├── baseline.coverage.json  # gcov output for a null invocation
│   ├── trace.ftrc              # cppfunctrace binary trace
│   ├── trace.perfetto-trace    # SQL-queryable form via trace_processor_shell
│   ├── trace.txt               # one ENTER/EXIT event per line: ts thread depth ENTER|EXIT symbol
│   ├── functions.txt           # sorted list of functions uniquely associated with the feature
│   └── sanity.json             # harness sanity-check results (coverage delta, top-N justifications)
├── F2-<slug>/
│   └── …
└── SUMMARY.md                  # one row per feature with function-count + notes
```

## Approach

For each feature `Fi` in `ATTACK_SURFACE.md`:

1. Build a **deterministic** fuzzer. Preference order — do NOT drop
   to a lower option when a higher one is available:

   1. **Real daemon via `configure-target.sh --traced`** — if the
      target ships a network-facing daemon reachable for this
      feature. `fuzz.sh` starts the daemon in the background, sends
      feature-specific bytes via a client that speaks the protocol,
      waits, SIGTERMs the daemon to flush cppfunctrace, then converts
      the `.ftrc` into BOTH `trace.perfetto-trace` (via `ftrc2perfetto`)
      AND `trace.txt` (via the cppfunctrace skill's text-export — one
      line per entry/exit: `ts thread depth ENTER|EXIT symbol`).
      `trace.txt` is what stage 7 greps for context; the Perfetto form
      is for power-user SQL queries.
   2. **CLI entry point** — for CLI-only targets, run
      `run-traced-<name>.sh` with crafted stdin / argv / input file.
   3. **Standalone library harness** — only if the target ships no
      daemon and no CLI. One-file C program linking
      `libcppfunctrace` + the upstream library. `fuzz.sh` must state
      why 1 and 2 weren't applicable.

   Picking option 3 when 1 is available is a stage-5 bug: the
   deployed product, not the library, is what we care about.

2. Run the same invocation against the coverage build (stage 1's
   `./build.sh coverage`); collect `coverage.json` via `gcov-coverage`.
3. `trace.ftrc` is already produced in step 1 (option 1/2); under
   option 3, produce it here.
4. Run a null invocation (empty / first-byte-rejected request);
   collect `baseline.coverage.json`.
5. `functions.txt = hit_by(Fi) \ hit_by(baseline)`, then intersect
   with `codenav reachable --from <Fi entry point>` to drop
   unrelated executions.
6. Sort `functions.txt` by importance: depth in callgraph × touches
   attacker-controlled data × allocates / frees / memcpys / parses.

7. **Sanity-check the harness** (record in `sanity.json`). Stage 3
   no longer names entry-point symbols — Stage 5 owns the feature→code
   mapping. The checks confirm the fuzzer actually drove the feature:

   - **Non-trivial delta:** `|hit_by(Fi)| - |hit_by(baseline)|` ≥ 5
     functions (or 1% of `|hit_by(Fi)|`, whichever is larger).
   - **Top-N spot check:** top 10 symbols in `functions.txt`, one
     sentence each justifying why this symbol plausibly belongs to
     `Fi`'s "What" / "How to exercise" description from
     `ATTACK_SURFACE.md`. If you can't justify membership for the
     top symbols, the fuzzer is exercising the wrong path — revise.

   ```json
   {
     "coverage_delta":       142,
     "baseline_size":        318,
     "feature_size":         460,
     "top_n_justifications": [
       {"symbol": "priority_handle", "reason": "PRIORITY frame dispatch — matches Fi's 'priority frame parsing'"},
       {"symbol": "stream_lookup",   "reason": "called from priority handler to resolve stream id"}
     ]
   }
   ```

   If any check fails, don't dispatch function-auditor for `Fi` —
   record in `SUMMARY.md` and skip.

8. **HARD GATE — run `validate-feature.sh` per feature, in turn.**

   ```bash
   $VULPINE_ROOT/tools/validate-feature.sh features/$feature/
   ```

   Checks: the artefacts in step 7 non-empty; `sanity.json`
   invariants; `trace.ftrc` + `trace.perfetto-trace` non-empty if
   the target ships a daemon (detected via `run-traced-*.sh`
   excluding `run-traced-harness-*.sh`). A failing feature must be
   fixed or explicitly marked skipped.

   Before returning, also run `--all`:
   ```bash
   $VULPINE_ROOT/tools/validate-feature.sh --all $VULPINE_RUN/features
   ```

Once all features are mapped, write `SUMMARY.md`.

## Fan-out to function-auditor

After `SUMMARY.md` is written, for every feature `Fi` **that passed the
sanity check in step 7** launch a `function-auditor` subagent via the Agent
tool. Skip features whose `sanity.json` reports a failure. Pass:

- `VULPINE_RUN=<abs path>`
- `feature=Fi-<slug>`
- `functions_file=$VULPINE_RUN/features/Fi-<slug>/functions.txt`
- `model=<propagated>`

Run them in parallel — send one Agent tool use per feature in a single
message. Wait for all of them to complete before returning.

## Skills

- `codenav` — for reachability, entry points.
- `gcov-coverage` — for coverage collection + diffing.
- `cppfunctrace` — for the ordered call-graph trace.
- `function-tracing` — alternative tracing if cppfunctrace is unavailable on
  the host.

## Footguns

- If a feature's fuzzer only exercises the parser and never reaches the real
  state machine, `functions.txt` will be shallow and misleading. Compare
  `|functions|` across features — outliers on the low end are usually broken
  harnesses, not simple features.
- Sanitizers abort-on-error lose gcov data unless you enable
  `-fprofile-update=atomic` and `__gcov_dump()` on signal. The
  `gcov-coverage` skill covers this.
- `functions.txt` should not exceed ~500 entries per feature; if it does,
  you've let in too much baseline noise — tighten the baseline.

## Return value

- For each feature: the number of functions in `functions.txt` and any that
  codenav flagged as virtual / templated (those need extra care in stage 6).
- Total function-audit subagents launched.
- Any feature you could not build a fuzzer for (stage 7 still reads those
  from `ATTACK_SURFACE.md`, but knows it's flying blind).

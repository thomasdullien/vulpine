---
name: attack-surface-mapping
description: Stage 5 of Vulpine. For each feature in ATTACK_SURFACE.md, produce a minimal deterministic fuzzer, collect gcov coverage + cppfunctrace traces while exercising it, and derive the set of functions uniquely associated with that feature. Then fan out a parallel function-auditor subagent per function-set. Invoke on "stage 5", "map attack surface to code", or "which functions correspond to feature X".
model: inherit
tools: Agent, Bash, Read, Write, Edit, Glob, Grep
---

# Attack Surface → Code Mapping (Stage 5)

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
│   ├── functions.txt           # sorted list of functions uniquely associated with the feature
│   └── sanity.json             # harness sanity-check results (entry-point hit, coverage delta, top-N justifications)
├── F2-<slug>/
│   └── …
└── SUMMARY.md                  # one row per feature with function-count + notes
```

## Approach

For each feature `Fi` in `ATTACK_SURFACE.md`:

1. Build a **deterministic** fuzzer. "Fuzzer" here does not have to be libFuzzer —
   it just has to be a small program or shell script that exercises the
   feature with a handful of meaningfully-different inputs. Deterministic =
   same output every run, no RNG seeded from time, no network races. If the
   feature is "HTTP/2 frame parser", a one-file C program that feeds the
   frame parser a hand-crafted PRIORITY frame is enough.
2. Run the fuzzer against the **coverage-instrumented** build (stage 1's
   `./build.sh coverage`) and collect `coverage.json` via the `gcov-coverage`
   skill.
3. Run the fuzzer against the **cppfunctrace** build and collect `trace.ftrc`.
4. Run a null invocation (no input, or an input that the feature's dispatch
   rejects early) and collect `baseline.coverage.json`.
5. Derive `functions.txt` as:

   ```
   functions = hit_by(Fi) \ hit_by(baseline)
   ```

   Then intersect with `codenav reachable --from <Fi entry point>` to drop
   any functions that happen to execute for unrelated reasons.
6. Sort `functions.txt` by a rough "how important to audit first" score:
   prefer functions that are (a) deep in the callgraph, (b) touch
   attacker-controlled data, (c) allocate / free / memcpy / parse.

7. **MANDATORY: Sanity-check the harness empirically.** A coverage diff that
   silently produces noise downstream is the worst failure mode of this stage.
   Before declaring `Fi` mapped, verify ALL of the following and record the
   results in `features/$feature/sanity.json`:

   - **Entry-point hit:** the documented entry-point symbol(s) for `Fi` from
     `ATTACK_SURFACE.md` MUST appear in both `coverage.json` and `trace.ftrc`.
     If they do not, the fuzzer is exercising the wrong code path — fix it
     before moving on. (Use `cppfunctrace`'s SQL interface to grep the trace.)
   - **Non-trivial coverage delta:** `|hit_by(Fi)| - |hit_by(baseline)|` MUST
     exceed a small threshold (default: 5 functions, or 1% of `|hit_by(Fi)|`,
     whichever is larger). A delta below that means the baseline is hitting
     the same code as the feature — tighten the baseline (use truly empty
     input, or input the dispatch rejects at the very first byte).
   - **Top-N spot check:** read the names of the top 10 functions in
     `functions.txt`. For each, write one sentence in `sanity.json` explaining
     why it plausibly belongs to `Fi`. If you cannot, the function-set is
     contaminated — investigate.

   `sanity.json` shape:

   ```json
   {
     "entry_points_seen":   ["http2_frame_dispatch", "h2_priority_handle"],
     "entry_points_missing": [],
     "coverage_delta":       142,
     "baseline_size":        318,
     "feature_size":         460,
     "top_n_justifications": [
       {"symbol": "h2_priority_handle", "reason": "documented entry point for PRIORITY frames"},
       {"symbol": "h2_stream_lookup",   "reason": "called from priority handler to resolve stream id"},
       ...
     ]
   }
   ```

   If any of these checks fails, do NOT fan out a function-auditor for `Fi`
   — record the failure in `SUMMARY.md` and move on.

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

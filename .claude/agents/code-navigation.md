---
name: code-navigation
description: Stage 2 of Vulpine. Given the build directory produced by stage 1, produce a Woboq-indexed, browsable, codenav-queryable representation of the codebase. Invoke when the orchestrator asks for "code nav prep" / "stage 2" or the user explicitly wants Woboq/codebrowser HTML + compile_commands.json for a target.
model: inherit
tools: Bash, Read, Write, Edit, Glob, Grep
---

# Code Navigation Preparation (Stage 2)

**When to use:** stage 1 has produced `$VULPINE_RUN/build/`, and the
orchestrator wants a Woboq-indexed, codenav-queryable representation of the
codebase.

Produce the cross-reference data every later stage uses to navigate the
target.

## Inputs

- `VULPINE_RUN` — run directory; stage 1's `build/` is here.

## Output contract

```
$VULPINE_RUN/nav/
├── compile_commands.json       # produced by Bear
├── woboq/                      # HTML cross-reference produced by codebrowser_generator
│   ├── index.html
│   └── …                       # file-level HTML with clickable xrefs
└── codenav-db/                 # codenav-indexed representation (if codenav builds its own index)
```

Also: a top-level `$VULPINE_RUN/nav/README.md` with the exact `codenav`
command line the later stages should use.

## Output JSON schema

```json
{
  "$schema": "https://json-schema.org/draft-07/schema#",
  "title":   "vulpine.stage-2.nav",
  "type":    "object",
  "description": "Layout of $VULPINE_RUN/nav/.",
  "required": ["compile_commands.json", "woboq/", "codenav-db/", "README.md"],
  "properties": {
    "compile_commands.json": {
      "type": "string",
      "description": "Bear-captured DB. Coverage of project translation units must be ≥ 95%; manual completion is allowed but must be reported."
    },
    "woboq/": {
      "type": "object",
      "description": "Two-pass codebrowser output. SKIPPING the indexgenerator pass leaves index.html missing.",
      "required": ["index.html", "fileIndex"],
      "properties": {
        "index.html": { "type": "string", "description": "Top-level browseable file tree from codebrowser_indexgenerator pass 2; non-empty; contains href links." },
        "fileIndex":  { "type": "string", "description": "Symbol/file index used by index.html." }
      }
    },
    "codenav-db/": { "type": "string", "description": "Codenav index; `codenav search main` must return a result." },
    "README.md": {
      "type": "object",
      "description": "Stage-2 summary; structured fields:",
      "required": ["tus_indexed", "symbols_indexed", "codenav_command"],
      "properties": {
        "tus_indexed":        { "type": "integer", "minimum": 0 },
        "symbols_indexed":    { "type": "integer", "minimum": 0 },
        "codenav_command":    { "type": "string", "description": "One-line codenav invocation later stages should run." },
        "manual_db_edits":    { "type": "boolean", "default": false,
                                "description": "True iff compile_commands.json had to be hand-completed." }
      }
    }
  }
}
```

## Approach

1. Inside the stage-1 container (or with the same toolchain), run the
   target's build under Bear to capture the compile commands:

   ```bash
   cd $VULPINE_RUN/build/src
   bear -- ./build.sh plain           # or the project's native build command
   cp compile_commands.json $VULPINE_RUN/nav/
   ```

   If Bear doesn't capture a command (e.g. because the project drives the
   compiler indirectly), fall back to `intercept-build` or to writing a
   `compile_commands.json` by hand from the CMake/Meson output. The file must
   be complete — if it's missing 10% of TU's, the later stages will have 10%
   blind spots.

2. Run Woboq codebrowser against the compile DB. This is a TWO-pass
   process — the per-file HTML produced by `codebrowser_generator` is
   not browsable on its own; the top-level `index.html` needs the
   file-tree index that `codebrowser_indexgenerator` builds in a
   second pass over the same output directory.

   ```bash
   # Pass 1: emit per-file HTML + cross-reference data.
   codebrowser_generator \
       -b $VULPINE_RUN/nav/compile_commands.json \
       -a \
       -o $VULPINE_RUN/nav/woboq \
       -d $VULPINE_RUN/nav/woboq-data \
       -p <project>:$VULPINE_RUN/build/src

   # Pass 2: build the file-tree + symbol-search index that
   # the top-level index.html links into. SKIPPING THIS PASS leaves
   # the HTML per-file but unbrowsable — every link from index.html
   # returns 404.
   codebrowser_indexgenerator \
       $VULPINE_RUN/nav/woboq \
       -d $VULPINE_RUN/nav/woboq-data
   ```

   Verify (ALL of these — `fileIndex` alone is NOT sufficient; empirical
   checks on prior runs show ~65% of nav/ outputs had `fileIndex` but
   missing `index.html`, rendering the whole tree unbrowsable):

   ```bash
   test -s $VULPINE_RUN/nav/woboq/index.html || {
     echo "pass 2 did not write index.html — re-run codebrowser_indexgenerator"
     exit 1
   }
   test -s $VULPINE_RUN/nav/woboq/fileIndex
   test -d $VULPINE_RUN/nav/woboq/<project>         # per-project subdir from pass 1
   grep -q 'href' $VULPINE_RUN/nav/woboq/index.html # non-empty file list
   ```

   If `index.html` is missing or empty, pass 2 was either skipped or
   run against the wrong output directory. Re-run with the exact
   `-o <nav/woboq>` path that pass 1 used; `codebrowser_indexgenerator`
   expects the same directory to walk.

   Follow the invocation the `codenav` skill documents.

3. Build / warm the codenav index using the `codenav` skill's own
   instructions. Verify it works by querying one non-trivial symbol (e.g.
   `main`) and checking that `codenav callers main` returns something
   plausible.

## Skills

- `codenav` — authoritative on how to build the index and on the exact query
  syntax. Read its SKILL.md before you start.

## Failure modes

- Missing TU's in the compile DB — see approach step 1. Report explicitly if
  you had to resort to manual editing.
- Woboq OOMs on very large projects. Increase Docker memory or split by
  directory and merge.

## Return value

- Report the number of TU's indexed, the number of C++ symbols codenav knows
  about, and the one-line `codenav` command the later stages should run
  (relative to `$VULPINE_RUN/nav/`).

---
name: code-navigation
description: Stage 2 of Vulpine. Given the build directory produced by stage 1, produce a Woboq-indexed, browsable, codenav-queryable representation of the codebase. Invoke when the orchestrator asks for "code nav prep" / "stage 2" or the user explicitly wants Woboq/codebrowser HTML + compile_commands.json for a target.
model: inherit
tools: Bash, Read, Write, Edit, Glob, Grep
---

# Code Navigation Preparation (Stage 2)

**When to use:** stage 1 has produced `$VULPINE_RUN/build/`; produce the
cross-reference data every later stage uses to navigate the target.

## Inputs

- `VULPINE_RUN` — run directory; stage 1's `build/` is here.

## Output contract

```
$VULPINE_RUN/nav/
├── compile_commands.json   # produced by Bear
├── woboq/                  # Woboq HTML cross-reference (two passes!)
│   ├── index.html          # top-level browseable tree (pass 2)
│   ├── fileIndex           # symbol index (pass 2)
│   └── <project>/          # per-file HTML (pass 1)
├── codenav-db/             # codenav index
└── README.md               # stage-2 summary + the codenav command-line
```

## Output JSON schema

```json
{
  "$schema": "https://json-schema.org/draft-07/schema#",
  "title":   "vulpine.stage-2.nav",
  "type":    "object",
  "required": ["compile_commands.json", "woboq/", "codenav-db/", "README.md"],
  "properties": {
    "compile_commands.json": { "type": "string",
        "description": "Bear-captured DB; ≥95% TU coverage; manual completion allowed but must be reported." },
    "woboq/": {
      "type": "object",
      "required": ["index.html", "fileIndex"],
      "properties": {
        "index.html": { "type": "string",
            "description": "Pass-2 output; non-empty; contains href links." },
        "fileIndex":  { "type": "string" }
      }
    },
    "codenav-db/": { "type": "string",
        "description": "`codenav search main` must return a result." },
    "README.md": {
      "type": "object",
      "required": ["tus_indexed", "symbols_indexed", "codenav_command"],
      "properties": {
        "tus_indexed":     { "type": "integer", "minimum": 0 },
        "symbols_indexed": { "type": "integer", "minimum": 0 },
        "codenav_command": { "type": "string" },
        "manual_db_edits": { "type": "boolean", "default": false }
      }
    }
  }
}
```

## Approach

### 1. Capture compile commands with Bear

```bash
cd $VULPINE_RUN/build/src
bear -- ./build.sh plain
cp compile_commands.json $VULPINE_RUN/nav/
```

If Bear misses commands (project drives the compiler indirectly), fall
back to `intercept-build` or hand-write entries from the CMake/Meson
output. The DB must be complete — 10% missing TUs means 10% blind spots
downstream.

### 2. Woboq codebrowser — two passes, both required

Pass 1 emits per-file HTML; pass 2 builds the file-tree index that
`index.html` links into. Skipping pass 2 is the most common stage-2
failure (every link from index.html 404s).

```bash
codebrowser_generator \
    -b $VULPINE_RUN/nav/compile_commands.json -a \
    -o $VULPINE_RUN/nav/woboq \
    -d $VULPINE_RUN/nav/woboq-data \
    -p <project>:$VULPINE_RUN/build/src

codebrowser_indexgenerator \
    $VULPINE_RUN/nav/woboq -d $VULPINE_RUN/nav/woboq-data
```

Verify all of these (`fileIndex` alone is NOT sufficient):

```bash
test -s $VULPINE_RUN/nav/woboq/index.html
test -s $VULPINE_RUN/nav/woboq/fileIndex
test -d $VULPINE_RUN/nav/woboq/<project>
grep -q href $VULPINE_RUN/nav/woboq/index.html
```

If `index.html` is missing, pass 2 was skipped or pointed at the wrong
output directory. Re-run with the exact `-o` path pass 1 used.

### 3. Build the codenav index

Follow the `codenav` skill's SKILL.md. Smoke-test:

```bash
codenav callers main | head    # must return something plausible
```

## Failure modes

- Missing TUs in the compile DB → report explicitly.
- Woboq OOMs on large projects → increase Docker memory or split by
  directory and merge.

## Skills

- `codenav` — authoritative on index build + query syntax. Read its
  SKILL.md before starting.

## Return value

- TUs indexed, symbols codenav knows about, and the one-line `codenav`
  command later stages should run.

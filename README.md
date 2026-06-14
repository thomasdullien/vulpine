# Vulpine

A multi-agent vulnerability-development pipeline. Feed it a repository URL and
(optionally) a commit hash; the agents build the target, model its attack
surface, fuzz each feature, audit every function on the hot path, look for
security flaws, and attempt to chain the best bugs into an exploit.

Vulpine ships with multi-platform agent definitions so the same pipeline runs on
**Claude Code**, **OpenCode**, and **Codex**, letting you benchmark different
backend models on the same vulndev workflow.

## Pipeline stages

| # | Agent                        | Produces                                                    |
|---|------------------------------|-------------------------------------------------------------|
| 1 | `build-preparation`          | `build/` — Dockerfile + source tree that builds clean with ASan/TSan/UBSan and with cppfunctrace instrumentation. |
| 2 | `code-navigation`            | `nav/` — Woboq HTML index + compile_commands.json + a ready-to-use `codenav` database. |
| 3 | `attack-surface`             | `ATTACK_SURFACE.md` — enumerated reachable features. |
| 4 | `configuration`              | `configure-target.sh` — turns the container into a realistic deployment. |
| 5 | `attack-surface-mapping`     | `features/<feature>/` — minimal deterministic fuzzer + gcov coverage → function set. Fans out to N copies of agent 6. |
| 6 | `function-auditor` (dispatcher) → `single-function-auditor` (worker, one per symbol on a clean context) | `audit-log.db` — intent vs. implementation summary for every Tier-A function, plus a ranked list of misbehaving ones. Each worker also writes a line-by-line Markdown reasoning trace under `features/<F>/audits/*.trace.md` so the per-symbol audit reasoning can be inspected and diffed across models. |
| 7 | `code-auditor` (+ `crash-analyzer` / `crash-analyzer-checker`) | `issues/<id>/` — report, minimal trigger, GDB verification script. For critical memory-corruption findings, drives a ≤4-round analyzer/checker loop producing an `evidence/` chain with real rr output; unresolved after 4 rounds → CONTESTED (severity capped at `high`). |
| 8 | `exploit-developer`          | `exploit/` — chained-bug exploit attempts + `EXPLOIT_LEARNINGS.md`. |

A top-level `vulpine-orchestrator` agent (Claude Code) / `/vulpine` command
(OpenCode) runs the stages in order and handles fan-out at stage 5.

## Skills / tools

Each skill is a Claude Code-format skill (`SKILL.md` + helpers) that lives in
its own upstream repository. Vulpine does not author skill content itself — it
just ships agents that reference skills **by name**. `install-tools.sh` clones
the upstream repos into `tools/src/` and the deploy scripts symlink each
`SKILL.md` directory into the Claude Code / OpenCode skill search paths.

| Skill name ( frontmatter ) | Upstream                                                                                                 |
|----------------------------|----------------------------------------------------------------------------------------------------------|
| `cppfunctrace`             | https://github.com/thomasdullien/cppfunctrace (dir `skill/`)                                             |
| `codenav`                  | https://github.com/thomasdullien/codenav                                                                 |
| `gcov-coverage`            | https://github.com/thomasdullien/ffmpeg-patch-analysis-claude/tree/main/gcov-coverage                    |
| `rr-debugger`              | https://github.com/thomasdullien/ffmpeg-patch-analysis-claude/tree/main/rr-debugger                      |
| `line-execution-checker`   | https://github.com/thomasdullien/ffmpeg-patch-analysis-claude/tree/main/line-execution-checker           |
| `function-tracing`         | https://github.com/thomasdullien/ffmpeg-patch-analysis-claude/tree/main/function-tracing                 |
| `fnaudit`                  | https://github.com/thomasdullien/fnaudit (skill dir `.claude/skills/fnaudit/`, installs the `fnaudit` Python CLI) |

For OpenCode (which has no native skills concept), the deploy script also
populates `~/.vulpine/skills/<name>/` so agent prompts can `@`-include the
same `SKILL.md` content.

For Codex, `scripts/deploy-codex.sh` generates user-scope custom agents under
`~/.codex/agents/` from the Claude agent prompts and links the same upstream
skills under `~/.agents/skills/`.

## Layout

```
vulpine/
├── README.md
├── VULPINE_INITIAL.md               # design brief (source of this scaffold)
├── .claude/
│   └── agents/                      # Claude Code subagents (one per stage + orchestrator)
├── .opencode/
│   ├── agents/                      # OpenCode mirrors of the same agents
│   └── commands/                    # OpenCode slash commands (/vulpine orchestrator)
├── scripts/
│   ├── install-tools.sh             # clone upstream skill repos into ./tools/src/
│   ├── deploy-claude.sh             # link agents + upstream skills into ~/.claude
│   ├── deploy-opencode.sh           # materialize agents + link commands into ~/.config/opencode,
│                                    # and materialize ~/.vulpine/skills/ for @-includes
│   └── deploy-codex.sh              # generate Codex custom agents + link skills
└── tools/src/                       # populated by install-tools.sh — upstream skill repos
```

## Quick start

```bash
# 1. Install external CLIs (cppfunctrace, codenav, rr helpers, gcov helpers).
./scripts/install-tools.sh

# 2a. Deploy to Claude Code (user scope).
./scripts/deploy-claude.sh

# 2b. Deploy to OpenCode (user scope).
./scripts/deploy-opencode.sh

# 2c. Deploy to Codex (user scope).
./scripts/deploy-codex.sh
```

After deployment:

- **Claude Code**: start `claude` in a working directory and run
  `Use vulpine-orchestrator for https://github.com/<org>/<repo> at <commit>`.
- **OpenCode**: start `opencode` and type `/vulpine <repo-url> [<commit>]`.
- **Codex**: start `codex` or run `codex exec` and explicitly ask it to spawn
  the `vulpine-orchestrator` custom agent for `<repo-url> [<commit>]`.

Each run writes its artifacts to `./run/<repo>-<commit>/<stage>/`.

## Evaluating different backend models

Every agent file in `.claude/agents/` and `.opencode/agents/` declares a `model`
field. To swap backends for a benchmark run, either edit those files or use the
per-platform override flags:

- Claude Code: `claude --model <id>` or `model: inherit` + a parent override.
- OpenCode: `opencode --model <provider/id>` or set `model` in `opencode.json`.
- Codex: `codex exec -m <id>` or a profile/config override.

The orchestrator accepts an optional `--model` argument that is propagated to
every subagent invocation.

## Status

This is a scaffold generated from `VULPINE_INITIAL.md`. Each agent encodes the
design brief as an executable prompt and lists the skills/tools it is expected
to use. Running the pipeline end-to-end on a real target requires:

1. The external CLIs built via `install-tools.sh`.
2. Docker with `--cap-add=SYS_PTRACE` for rr + sanitizers.
3. A working directory with enough space for the build, Woboq index, and fuzz
   corpora (expect ≥10 GB for non-trivial targets).

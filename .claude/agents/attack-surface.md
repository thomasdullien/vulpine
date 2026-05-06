---
name: attack-surface
description: Stage 3 of Vulpine. Given the target's source tree and documentation, produce ATTACK_SURFACE.md — an enumerated list of features an attacker can exercise in a typical deployment. Documentation-driven, not code-driven; do NOT claim file:line entry points (Stage 5 maps features to code via traces). Invoke on "stage 3", "attack surface", or "what features can an attacker reach".
model: inherit
tools: Bash, Read, Write, Glob, Grep, WebFetch, WebSearch
---

# Attack Surface (Stage 3)

**When to use:** stages 1 and 2 are done; the orchestrator wants a
documentation-driven enumeration of the features an attacker can drive
against a typical deployment.

Documentation is the only source. Do NOT name file:line entry points or
"key functions" — Stage 5 owns the feature→code mapping via real client
traces, and any code anchor you produce here is a guess that downstream
stages cannot rely on.

## Inputs

- `VULPINE_RUN` — `build/` and `nav/` are populated. You may use `nav/`
  *only* to confirm compile-time gating (e.g. that `--enable-X` was on).

## Output contract

`$VULPINE_RUN/ATTACK_SURFACE.md`:

```markdown
# Attack Surface: <target>

## Summary
One paragraph: typical deployment shape; attacker classes (remote
pre-auth, remote post-auth, local unprivileged, file-format victim, …).

## Features

### F1. <concise name>
- **What:** protocol/file-format/config shape (e.g. "LDAP Bind request",
  "SDP attribute parsing in SIP INVITE body").
- **Documentation source:** RFC §, man page, docs section.
- **Attacker control:** bytes the attacker shapes; pre/post-auth and
  config gating.
- **How to exercise:** one-line client invocation that drives the feature
  (`ldapsearch -x -b … -s base`, `curl -X POST --data-binary @body.bin`,
  …). Stage 5 will turn this into a real fuzzer.

### F2. …
```

Cover what the docs support — don't pad, don't under-list.

## Output JSON schema

The Markdown must serialise to this shape (stage 5 parses it by section):

```json
{
  "$schema": "https://json-schema.org/draft-07/schema#",
  "title":   "vulpine.stage-3.attack-surface",
  "type":    "object",
  "required": ["target", "summary", "features"],
  "properties": {
    "target":  { "type": "string" },
    "summary": { "type": "string" },
    "features": {
      "type": "array",
      "minItems": 1,
      "items": {
        "type": "object",
        "required": ["id", "name", "what", "doc_source",
                     "attacker_control", "how_to_exercise"],
        "properties": {
          "id":               { "type": "string", "pattern": "^F[0-9]+$" },
          "name":             { "type": "string" },
          "what":             { "type": "string" },
          "doc_source":       { "type": "string" },
          "attacker_control": { "type": "string" },
          "how_to_exercise":  { "type": "string" },
          "compile_gated":    { "type": "boolean", "default": false },
          "excluded":         { "type": "boolean", "default": false },
          "excluded_reason":  { "type": "string" }
        }
      }
    }
  }
}
```

## Approach

1. Read the project's `README`, docs, `man/`, `SECURITY.md`. Project
   deployment docs are the primary source.
2. Skim the wire/file-format specs the project implements. RFC sections
   and IANA registries enumerate request types, header fields, content
   types — each is a candidate feature. List well-tested ones too;
   stage 5 re-ranks by what actually fires.
3. Use `nav/` only for compile-time-gating confirmation. Do NOT walk
   callgraphs or claim entry-point symbols.

Do NOT search for historical CVEs — they anchor attention to bugs
already fixed; stage 7 hunts new defects.

## Footguns

- A compile-flag-gated feature the default build doesn't enable: list
  it but de-prioritise.
- Internal API surface (functions only called by the project's own
  tests) is not attacker-reachable; skip.
- file:line guesses mislead stage 5/7. Don't make them.

## Skills

- `codenav` — compile-time-gating confirmation only.

## Return value

- Number of features identified; one-line headline of each.
- Features deliberately excluded and why.

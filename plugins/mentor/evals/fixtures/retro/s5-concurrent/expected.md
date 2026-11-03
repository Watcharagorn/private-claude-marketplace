# Expected: s5-concurrent

Two Claude sessions live in one project (`-tmp-retro-fixture-proj`), with
different opening prompts and no session id supplied. Identity must resolve by
unique cwd + opening-prompt match, or fall back to `partial` — never pick the
newest file.

## Fixture wiring

- Run the retro with `--claude-config <scratch>/claude-config`.
- No `__FIXTURE__` placeholders.
- Two session files in the same project dir:
  - `s5aaaaa0-...0001.jsonl` — older (opening 2026-11-01T08:00), opening prompt
    "Refactor the marketplace sync script to stream manifests."
  - `s5bbbbb0-...0002.jsonl` — newer (opening 2026-11-01T09:30), opening prompt
    "Document the capability matrix in the mentor README."
- The newer file is `s5bbbbb0-...0002`. The test must not rely on copied-file
  mtime; "newer" means the later opening-event timestamp.

## Case A — explicit opening prompt given

When the retro is given the opening prompt
"Refactor the marketplace sync script to stream manifests" (and no session id):

```
identity:
  host: claude
  method: prompt-match
  detail: "unique cwd + opening-prompt match → s5aaaaa0-0000-4000-8000-000000000001"
coverage: complete
cutoff:
  node: n-root
  event: p5-0000-4000-8000-000000000002
```

The unique match wins: the OLDER file `s5aaaaa0-...0001` is selected, proving
selection is by prompt, not by recency.

## Case B — no session id and no opening prompt

```
identity:
  host: claude
  method: partial
  detail: "two sessions in /tmp/retro-fixture-proj, no id and no opening prompt to disambiguate"
coverage: partial
cutoff:
  node: null
  event: null
```

The result is labelled `partial`. The retro must NOT pick the newest file
(`s5bbbbb0-...0002`); it selects nothing and reports partial.

## Nodes / skipped

Case A: one `root` node `n-root` for `s5aaaaa0-...0001` (events 2, one epoch
`end`). Case B: `nodes: []`, `skipped: [{node: null, reason: "ambiguous identity;
two concurrent sessions, no disambiguator"}]`.

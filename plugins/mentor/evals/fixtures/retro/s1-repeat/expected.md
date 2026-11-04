# Expected: s1-repeat

Plain Claude session, no delegates, no compaction. The user runs the same
3-step client-regeneration procedure twice: `make openapi` →
`npm run gen:client` → `npm test -- client`.

## Fixture wiring

- Run the retro with `--claude-config <scratch>/claude-config`.
- No `__FIXTURE__` placeholders are used in this fixture (no agt store).
- The test runner copies this fixture to a scratch dir before running; paths
  inside the transcript (`cwd: /tmp/retro-fixture-proj`) stay literal.
- Project dir name is `-tmp-retro-fixture-proj` for cwd `/tmp/retro-fixture-proj`.
- Session id: `s1aaaaa0-0000-4000-8000-000000000001`.

## Manifest assertions (shared MANIFEST SCHEMA)

```
cutoff:
  node: n-root
  event: a1-0000-4000-8000-000000000008   # last assistant uuid at retro start
identity:
  host: claude
  method: explicit            # id/path given; else native via CLAUDE_CODE_SESSION_ID
  detail: "sessionId s1aaaaa0-0000-4000-8000-000000000001 matched file"
coverage: complete
nodes:
  - id: n-root
    kind: root
    parent: null
    host: claude
    role: orchestrator
    source_path: claude-config/projects/-tmp-retro-fixture-proj/s1aaaaa0-0000-4000-8000-000000000001.jsonl
    digest_path: evidence/digest/n-root.jsonl
    brief: "Regenerate the TypeScript client: bundle, generate, test."
    outcome: "client regenerated twice, tests pass"
    opaque: false
    opaque_reason: null
    epochs:
      - n: 1
        from: u1-0000-4000-8000-000000000001
        to: a1-0000-4000-8000-000000000008
        ends_with: cutoff
        trigger: null
    events: 16
    replayed_dropped: 0
skipped: []
```

## Expected synthesis rows

- Exactly **one Accepted new-skill row** for the 3-step client-regeneration
  procedure (`make openapi` → `npm run gen:client` → `npm test -- client`).
  The procedure was performed twice in one session, which clears the
  repeatable bar (2+ times). The procedure deliberately has no existing skill
  home, so existing-skill-first does not turn it into a description tune of
  another skill.
- Destination: `.claude/skills/<name>` plus a **relative** symlink
  `.codex/skills/<name>` (the workspace's documented skill-storage convention;
  the test seeds it in the scratch project's CLAUDE.md).
- No Rejected or Backlog rows are required by this fixture.

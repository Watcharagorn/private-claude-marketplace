# Expected: s2-claude-orchestrator (covers S2 and S4)

Claude Code orchestrator. One OLD root file and one RESUMED root file that
replays the old events (same uuids) and carries a `last-prompt` trailer
pointing at the OLD sessionId. The resumed file holds 2 `compact_boundary`
entries → 3 epochs. The user corrects the agent in epoch 1 ("never use
`git add -A`, stage exact paths") and the agent runs `git add -A` again in
epoch 3. One Claude subagent (`code-reviewer`). Two agt workers: one claude
(with a transcript), one kiro (`session_id: null`, shell blocked → opaque).

## Fixture wiring

- Run the retro with `--claude-config <scratch>/claude-config`,
  `--agt-home <scratch>/agt-home` and
  `--until r2-0000-4000-8000-000000000016` (freeze the cutoff explicitly at the
  "Staged everything. Ready to commit." event, so the two later events are proven
  excluded rather than excluded only because they are the file's tail).
- After the `__FIXTURE__` copy step the store roots are `<copy>/claude-config`
  (the orchestrator config root) and `<copy>/agt-home` (the agt router home).
- `__FIXTURE__` placeholders appear in agt `spec.json` (`parent.config_dir`)
  and `status.json` (`attempts[].home`). The test runner copies the fixture to
  a scratch dir and replaces every `__FIXTURE__` with the copy's absolute path,
  so `__FIXTURE__/worker-claude-config` resolves to the claude worker's config
  root and `__FIXTURE__/claude-config` to the orchestrator's.
- Project dir name `-tmp-retro-fixture-proj` for cwd `/tmp/retro-fixture-proj`.
- OLD sessionId `s2aaaaa0-0000-4000-8000-000000000001`; RESUMED sessionId
  `s2bbbbb0-0000-4000-8000-000000000002`.

## Cutoff

```
cutoff:
  node: n-root-resume
  event: r2-0000-4000-8000-000000000016   # "Staged everything. Ready to commit."
```

The two events AFTER the cutoff — `r2-...017` ("Actually hold on, let me
review…") and `r2-...018` ("Holding. Nothing committed.") — must NOT appear in
any node's counted events; the retro started at `r2-...016`.

## Identity

```
identity:
  host: claude
  method: native            # CLAUDE_CODE_SESSION_ID verified against file sessionId
  detail: "resumed file sessionId s2bbbbb0-...0002; last-prompt trailer links the OLD sessionId s2aaaaa0-...0001"
```

## Coverage

```
coverage: complete          # every node and epoch read or skipped-with-reason; the only
                            # opaque node (kiro worker) is opaque-with-reason, not skipped
```

## Nodes

```
nodes:
  - id: n-root-old
    kind: root
    parent: null
    host: claude
    role: orchestrator
    source_path: claude-config/projects/-tmp-retro-fixture-proj/s2aaaaa0-0000-4000-8000-000000000001.jsonl
    digest_path: evidence/digest/n-root-old.jsonl
    brief: "Stage and commit the mentor changes (pre-resume)."
    outcome: "superseded by the resumed file"
    opaque: false
    opaque_reason: null
    epochs:
      - n: 1
        from: o2-0000-4000-8000-000000000001
        to: o2-0000-4000-8000-000000000005
        ends_with: end
        trigger: null
    events: 5
    replayed_dropped: 0

  - id: n-root-resume
    kind: resume
    parent: n-root-old
    host: claude
    role: orchestrator
    source_path: claude-config/projects/-tmp-retro-fixture-proj/s2bbbbb0-0000-4000-8000-000000000002.jsonl
    digest_path: evidence/digest/n-root-resume.jsonl
    brief: "Resume: finish staging and commit; delegated README review and dual-host checks."
    outcome: "held before commit at user's request; nothing committed"
    opaque: false
    opaque_reason: null
    epochs:
      - n: 1
        from: o2-0000-4000-8000-000000000001
        to: cb2-0000-4000-8000-00000000c001
        ends_with: compaction
        trigger: auto
      - n: 2
        from: r2-0000-4000-8000-000000000006
        to: cb3-0000-4000-8000-00000000c002
        ends_with: compaction
        trigger: manual
      - n: 3
        from: r2-0000-4000-8000-000000000013
        to: r2-0000-4000-8000-000000000016
        ends_with: cutoff
        trigger: null
    # The 5 replayed events (o2-...001..005) are dropped from this resumed node
    # (replayed_dropped: 5) and counted once in n-root-old, which owns the originals.
    # Events after the cutoff (r2-...017, r2-...018) are excluded.
    events: 11
    replayed_dropped: 5

  - id: n-subagent-rev01
    kind: subagent
    parent: n-root-resume
    host: claude
    role: code-reviewer
    source_path: claude-config/projects/-tmp-retro-fixture-proj/s2bbbbb0-0000-4000-8000-000000000002/subagents/agent-rev01.jsonl
    digest_path: evidence/digest/n-subagent-rev01.jsonl
    brief: "Review adapter README"    # from .meta.json description, verbatim
    outcome: "README reads cleanly, no blocking issues"
    opaque: false
    opaque_reason: null
    epochs:
      - n: 1
        from: sa2-0000-4000-8000-00000000a001
        to: sa2-0000-4000-8000-00000000a004
        ends_with: end
        trigger: null
    events: 4
    replayed_dropped: 0
    # linked by .meta.json toolUseId == toolu_r2_agent_1 (the Agent tool_use in epoch 2)

  - id: n-agt-claude
    kind: agt-worker
    parent: n-root-resume
    host: claude
    role: validate              # agt group role
    source_path: worker-claude-config/projects/-tmp-retro-fixture-proj/w2ccccc0-0000-4000-8000-000000000003.jsonl
    digest_path: evidence/digest/n-agt-claude.jsonl
    brief: "run verify-plugin-edits mentor"
    outcome: "14 pass / 0 fail"
    opaque: false
    opaque_reason: null
    epochs:
      - n: 1
        from: w2-0000-4000-8000-00000000b001
        to: w2-0000-4000-8000-00000000b004
        ends_with: end
        trigger: null
    events: 4
    replayed_dropped: 0
    # linked: result "[agt] DONE · … · job g-a1b2c3d4" → state/groups/g-a1b2c3d4.json
    # → jobs/j-claude-0001/status.json attempts[0].home=__FIXTURE__/worker-claude-config,
    #   session_id=w2ccccc0-...0003 → the transcript above

  - id: n-agt-kiro
    kind: agt-worker
    parent: n-root-resume
    host: kiro
    role: validate
    source_path: null
    digest_path: null
    brief: "run the shell smoke test"
    outcome: "shell blocked; checks NOT RUN"     # from result.md
    opaque: true
    opaque_reason: "status.json attempts[].session_id is null; kiro worker has no linked transcript — brief + result.md + stderr only"
    epochs: []
    events: 0
    replayed_dropped: 0
    # linked: result "[agt] DONE · … · job g-e5f6a7b8" → state/groups/g-e5f6a7b8.json
    # → jobs/j-kiro-0001 (provider kiro:xhigh)
```

## Skipped

```
skipped: []
```

## Expected synthesis rows

- One **Accepted** row that cites BOTH the epoch-1 correction (user: "never use
  `git add -A` … stage exact paths only", event `o2-...003`) AND the epoch-3
  repeat (agent ran `git add -A` again at event `r2-...014`). This is the
  correction lost across a compaction that the continuity section must catch.
  Destination: an edit/tune to the repo's git-staging guidance (or a new skill),
  `.claude/skills/<name>` + relative `.codex/skills/<name>`.
- A **Leftover** item: "the kiro agt worker had no shell" → an **agt-config
  proposal** (change another tool's config), never applied by the retro.

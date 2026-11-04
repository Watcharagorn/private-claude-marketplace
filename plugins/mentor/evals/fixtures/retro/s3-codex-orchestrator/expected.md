# Expected: s3-codex-orchestrator

Codex orchestrator. A parent rollout with one `compacted` item (→ 2 epochs) and
a `spawn_agent` function_call, plus one child rollout linked by
`session_meta.parent_thread_id`.

## Fixture wiring

- Run the retro with `--codex-home <scratch>/codex-home`.
- No `__FIXTURE__` placeholders (no agt store in this fixture).
- Rollouts live under `codex-home/sessions/2026/11/01/`.
- Parent thread id `th-parent-0000000000000001`; child thread id
  `th-child-00000000000000c2`.
- Identity resolves the parent via `$CODEX_THREAD_ID` verified against
  `session_meta.id`.

## Cutoff

```
cutoff:
  node: n-root
  event: 12                 # last item ordinal of the parent rollout at retro start
                            # (1-based; the final assistant "Release is ready" message)
```

## Identity

```
identity:
  host: codex
  method: native            # CODEX_THREAD_ID verified against session_meta.id
  detail: "parent session_meta.id th-parent-0000000000000001"
```

## Coverage

```
coverage: complete
```

## Nodes

```
nodes:
  - id: n-root
    kind: root
    parent: null
    host: codex
    role: orchestrator
    source_path: codex-home/sessions/2026/11/01/rollout-2026-11-01T12-00-00-th-parent-0000000000000001.jsonl
    digest_path: evidence/digest/n-root.jsonl
    brief: "Release mentor on Codex: bump, sync, verify, delegate adapter review."
    outcome: "verify 14 pass / 0 fail; reviewer clear; release ready"
    opaque: false
    opaque_reason: null
    epochs:
      - n: 1
        from: 1            # session_meta is item 1
        to: 6              # the compacted item
        ends_with: compaction
        trigger: null      # Codex compacted items carry no auto/manual trigger field
      - n: 2
        from: 7            # the continuation user message
        to: 12
        ends_with: cutoff
        trigger: null
    events: 12
    replayed_dropped: 0

  - id: n-codex-child-review
    kind: codex-child
    parent: n-root
    host: codex
    role: review            # from session_meta.source.subagent
    source_path: codex-home/sessions/2026/11/01/rollout-2026-11-01T12-05-00-th-child-00000000000000c2.jsonl
    digest_path: evidence/digest/n-codex-child-review.jsonl
    brief: "Review the mentor adapters for blocking issues."
    outcome: "adapters read cleanly, no blocking issues"
    opaque: false
    opaque_reason: null
    epochs:
      - n: 1
        from: 1
        to: 5
        ends_with: end
        trigger: null
    events: 5
    replayed_dropped: 0
    # linked: session_meta.parent_thread_id == th-parent-0000000000000001;
    # motivated by the parent's spawn_agent call_id call_s3_spawn_1
```

## Skipped

```
skipped: []
```

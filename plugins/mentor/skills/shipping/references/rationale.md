# shipping — rationale

Why the rules in `SKILL.md` are shaped the way they are — read this only when editing the skill or about to override one of its rules.

## Step 3 — why /simplify stays in-thread

Simplify is a review step, which makes wrapping this call in an
`Agent` dispatch a tempting read — but it is the one thing that breaks the step. Simplify
already runs its own agents, so the wrapper adds no parallelism; what it does add is a
delegate that commits its own result and returns "done". Everything numbered after the call in
Step 3 then becomes dead code — including the out-of-scope question — and the **Re-entry** paragraph
that lands you at Step 4 never fires, so the ship tail's two `AskUserQuestion` gates are
skipped and the push happens without the user ever choosing to test or choosing where the
branch goes. Keep the call in-thread and this step keeps its checks.

## Step 7 — why the test command is saved after the push

This lands in Step 7 and not in Step 4 on purpose. `.mentor/config.json` is
deliberately **not** gitignored — it is meant to be committed and shared — so
writing it is a working-tree change, and Step 4 sits *after* the Step 2/3 clean
gate and *before* the Step 5 push. Writing it there would leave the tree dirty
at push time in a skill whose Step 2 refuses to stage anything on the user's
behalf, and the next `/mentor:ship` would then abort at that very gate. After
the push, the same write is just a file waiting to be committed.

## Step 7 — how the config.json merge works

This is an in-place `jq` merge through a temp file, and that shape is the point: the `.k = $v`
assignment preserves every other key (`constitution_path`, the context-gate keys, any legacy ones), and
the `&&` means a `jq` failure leaves the original byte-identical — so there is
no second backup-and-restore dance to keep true for the same file. On the
create branch, a config written without `.mentor/.gitignore` beside it would
leave `plans/` and `reviews/` committable, so run
`mentor_ensure_gitignore` (as every hook that writes this file does) or create
the config only in a repo that already planned.

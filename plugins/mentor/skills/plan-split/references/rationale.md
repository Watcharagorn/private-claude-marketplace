# plan-split — rationale

Mechanism behind rules stated in `SKILL.md`. Load when editing the skill or about to override
one of these rules.

## Step 4 — why mint before any worker writes

`ensure-dir` stamps `owner`/`owner_session` on a plan-topic dir the instant it is
minted (a direct child of `plans/` — see `plan-state.sh`'s `ensure-dir` contract,
v2.23.0). Minting all N children here, before any subagent writes, closes the
unowned window: if a child's directory instead came into existence via the
worker's own `Write` call, that child would sit **unowned** — and, being
freshly written, **newer than every live marker in the repo** — for the whole
window until Step 6.1 registers it. An unowned plan newer than a marker is exactly
what a sibling worktree's `approve-plan.sh` sweeps when no sibling marker is live
("solo back-compat"), and if the split flow aborts partway, a child minted only by
`Write` stays permanently unowned. Mint first, and every child is owned by this
worktree from its very first byte on disk.

## Step 6 — why register per child

Registering per child, as it verifies, matters
for the same reason Step 4 mints before any worker starts: batching registration until
every child exists would leave each already-verified child relying on nothing
but its mint-time stamp for the whole remaining verification window, and if the
split flow aborts before the last child lands, every child verified-but-never-
registered would carry no `group`/`order` at all — permanently, since nothing
else writes them.

## Step 6 — why children inherit the parent's state

Without this, splitting after approval — in a fresh session with no marker FOR
THIS WORKTREE for `approve-plan.sh` to compare against, or in a worktree whose
live marker belongs to a DIFFERENT worktree (so `approve-plan.sh`'s ownership
filter excludes these children even though a marker exists) — yields children
stuck at `draft` with no approval path. A dead end with no way out.

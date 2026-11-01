# Claude Code adapter

Claude Code discovers the command facades in `commands/` and the lifecycle hooks in
`hooks/hooks.json`. Those surfaces add the enforced edit gate, context checks, the
`plan-continue.sh` Stop hook that keeps an approved run going until a terminal state,
foreground verifier subagents, and hosted Artifact publishing on top of the portable
skills and `.mentor/` state contract.

The skills remain the source of workflow behavior. A Claude command should route to
its matching skill instead of duplicating that behavior here.

---
name: vacuum-db
description: Run VACUUM ANALYZE on a Postgres database to reclaim space and refresh planner statistics, then report the largest tables. Use when asked to vacuum, analyze, reclaim space, or refresh stats on a Postgres DB.
version: 0.2.0
---

# Vacuum DB

Reclaim space and refresh planner statistics on a Postgres database.

## When to use
- "vacuum analyze the <db> database"
- "reclaim space / refresh planner stats on <db>"

## Steps
1. Run `psql <db> -c 'VACUUM ANALYZE;'`.
2. Report the top tables by total relation size (`pg_total_relation_size`).

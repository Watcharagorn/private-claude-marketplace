#!/usr/bin/env python3
"""Seed the scratch project with a realistic .mentor tree.

Without this, a query like "is the invoice plan any good?" makes the model hunt for a
file that doesn't exist and answer empty-handed — which scores as "did not trigger"
and is indistinguishable from a genuinely weak description. Seeding removes that
confound so the eval measures the descriptions and nothing else.
"""
import json, sys
from pathlib import Path

ROOT = Path(sys.argv[1] if len(sys.argv) > 1 else "project")
PLANS = ROOT / ".mentor" / "plans"


def plan_md(title, n_of, group, owns, not_touch, steps, ticked=0):
    hdr = ""
    if n_of:
        i, n = n_of
        hdr = (f"> [!NOTE]\n> **Plan {i} of {n}** · group `{group}`\n"
               f"> **Owns:** {owns}\n> **Does NOT touch:** {not_touch}\n\n")
    body = [f"# {title}\n", hdr, "## Context\n\nSeeded fixture plan.\n",
            "## Implementation steps\n"]
    for s in range(1, steps + 1):
        tick = " ✅" if s <= ticked else ""
        body.append(f"{s}. Step {s} of {title}.{tick}\n")
    body.append("\n## Verification\n\nRun the suite.\n")
    return "".join(body)


SPEC = [
    # slug, state, group, order, plan args
    ("multi-tenant-billing", "superseded", None, None,
     dict(title="Multi-tenant billing", n_of=None, group=None, owns="", not_touch="", steps=19)),
    ("metering-pipeline", "approved", "multi-tenant-billing", 1,
     dict(title="Metering pipeline", n_of=(1, 3), group="multi-tenant-billing",
          owns="src/metering/**", not_touch="invoicing → `billing-invoice`", steps=6)),
    ("billing-invoice", "approved", "multi-tenant-billing", 2,
     dict(title="Billing invoice", n_of=(2, 3), group="multi-tenant-billing",
          owns="src/billing/invoice/**, the `/v1/invoices` route",
          not_touch="metering → `metering-pipeline` · tenant scoping → `tenant-data-isolation`", steps=7)),
    ("tenant-data-isolation", "in_progress", "multi-tenant-billing", 3,
     dict(title="Tenant data isolation", n_of=(3, 3), group="multi-tenant-billing",
          owns="src/tenancy/**", not_touch="invoicing → `billing-invoice`", steps=5, ticked=2)),
    ("auth-jwt-rotation", "implemented", None, None,
     dict(title="Auth JWT rotation", n_of=None, group=None, owns="", not_touch="", steps=4, ticked=4)),
]

for slug, state, group, order, kw in SPEC:
    d = PLANS / slug
    d.mkdir(parents=True, exist_ok=True)
    (d / "plan.md").write_text(plan_md(**kw))
    sc = {"state": state, "note": ""}
    if group:
        sc["group"] = group
        sc["order"] = order
    (d / ".state.json").write_text(json.dumps(sc, indent=2))

# a live handoff note, so /mentor:resume has something real to resume
hd = PLANS / "multi-tenant-billing" / "handoffs"
hd.mkdir(parents=True, exist_ok=True)
(hd / "2026-07-24-billing.md").write_text(
    "# Handoff — multi-tenant billing\n\n## Current state\n\n"
    "Stopped partway through the billing work yesterday afternoon.\n"
    "Metering is approved and unstarted; tenant-data-isolation is 2/5 steps in.\n\n"
    "## Next steps\n\nResume tenant-data-isolation at step 3.\n")

print(f"seeded {len(SPEC)} plans + 1 handoff note under {PLANS}")
for p in sorted(PLANS.glob("*/plan.md")):
    print("   ", p.relative_to(ROOT))

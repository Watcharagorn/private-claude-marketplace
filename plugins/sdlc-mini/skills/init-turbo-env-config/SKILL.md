---
name: init-turbo-env-config
description: >
  DEPRECATED / retired. This skill configured environment via the old **rogue.py** template model
  (`${CONFIG.ENV.*}` / `${SECRET.ENV.*}` resolved from S3), which NTBX has retired. Do not use it.
  It now only **redirects** to the replacement skills. Trigger phrases kept so old invocations land
  here: "/init-turbo-env-config", "convert env config", "setup rogue config", "init env template",
  "generate env template". For the real work use the devflow skills named below.
allowed-tools: Read
---

# init-turbo-env-config — DEPRECATED (rogue.py retired)

> This skill is a **tombstone**. The `rogue.py` + template-file config model it implemented
> (`${CONFIG.ENV.*}` / `${SECRET.ENV.*}` resolved from S3 at container start) has been **retired**.
> Do **not** generate templates or `rogue.py` wiring.

Config is now read directly from the **process environment**, which the **thanos** deployment system
supplies per app × environment. Use the replacement skills in the **devflow** plugin:

| You want to… | Use |
|---|---|
| Understand/author the per-framework config loader (Go/.NET/Node/Python/Java), fail-fast, no rogue | **`/devflow:config-from-env`** |
| Convert a project off rogue, or scaffold a new one, and build its env-var catalog | **`/devflow:thanos-env-vars-scaffold`** |
| Set/link the env vars into thanos for an app × environment | **`/devflow:thanos-env-vars-setup`** |

Start with **`/devflow:thanos-env-vars-scaffold`** — it detects legacy-rogue state, retires it, and
hands a catalog to `/devflow:thanos-env-vars-setup`. Do nothing else here.

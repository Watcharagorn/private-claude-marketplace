---
name: init-turbo-manifest
description: >
  DEPRECATED / moved. This skill set up `turbo-manifest.yml` for monorepo deployment; it has
  **moved to the devflow plugin** as `turbo-manifest`. Do not use it here — it now only
  **redirects**. Trigger phrases kept so old invocations land here: "/init-turbo-manifest",
  "setup turbo manifest", "generate turbo manifest", "init deployment manifest",
  "create turbo-manifest". For the real work use the devflow skill named below.
allowed-tools: Read
---

# init-turbo-manifest — DEPRECATED (moved to devflow)

> This skill is a **tombstone**. The `turbo-manifest.yml` deployment-manifest workflow it
> implemented has **moved to the devflow plugin** as the `turbo-manifest` skill, next to the
> `thanos-env-vars-*` deployment-config skills. Do **not** generate a manifest from here.

Invoke the replacement instead:

| You want to… | Use |
|---|---|
| Init / add-app / validate / migrate / explain `turbo-manifest.yml` | **`/devflow:turbo-manifest`** |

The devflow skill ships an **upgraded schema** (adds `healthcheck`, `publish`, `api_docs`, and the
`external` app type) and uses the new canonical schema URL
`https://raw.ntb.co.th/ntbx/schema-files/monorepo/turbo-manifest.schema.v1.json` (the old S3 URL is
dead). Run **`/devflow:turbo-manifest`** and do nothing else here.

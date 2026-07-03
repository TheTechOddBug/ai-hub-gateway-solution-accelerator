# 🏷️ Release Version Management Guide

This guide explains the versioning model of the Citadel Governance Hub accelerator, what each
version track in [`release.json`](../release.json) means, how versions are surfaced at runtime, and
how to plan and implement migrations when a version changes.

> [!IMPORTANT]
> **The primary accelerator deployment (`bicep/infra/main.bicep`) is for the _initial_
> implementation only.** Once the hub is established, the **[APIM Gateway Upgrade](../bicep/infra/apim-gateway-upgrade/README.md)**
> submodule is the standard, supported way to adopt new accelerator releases — it applies the new
> version in place (policies, APIs, backends, fragments, named values, and the `/version` manifest)
> **without re-provisioning** the APIM service or the surrounding landing-zone infrastructure.
> Re-running the full `main.bicep` for version upgrades is not the intended path and risks
> unnecessary churn on already-provisioned resources.

---

## Overview

The accelerator ships a single source-of-truth version manifest at the repository root:
[`release.json`](../release.json). Rather than a single monolithic version, the accelerator uses
**independent, component-scoped version tracks** so that a change in one subsystem (for example the
routing policy logic) does not force a full re-versioning of unrelated subsystems (for example usage
ingestion).

```jsonc
{
    "master-version": "1.0.0",
    "routing-version": "1.0.0",
    "backend-contract-version": "1.0.0",
    "access-contract-version": "1.0.0",
    "gateway-upgrade-version": "1.0.0-preview",
    "usage-ingestion-version": "1.0.0"
}
```

All version tracks follow [Semantic Versioning](https://semver.org/) (`MAJOR.MINOR.PATCH`), with an
optional pre-release suffix (for example `-preview`):

- **MAJOR** — breaking change. Requires a planned migration (contract change, path change, or
  behavioral change that existing consumers/configurations depend on).
- **MINOR** — backward-compatible feature addition. Safe to adopt without consumer changes.
- **PATCH** — backward-compatible fix. Safe to adopt without consumer changes.
- **`-preview`** — the track is functional but the surface may still change before it is declared
  stable. Pin to an exact version in production and validate before upgrading.

---

## Version Tracks

| Track | Scope | What changes it | Owned by |
|-------|-------|-----------------|----------|
| **`master-version`** | The overall accelerator release. Acts as the umbrella "product" version that consumers cite when reporting the deployed release. Bumped whenever any component track has a notable change. | Any coordinated release. | Whole repo |
| **`routing-version`** | The LLM request routing logic — backend pool selection, model-to-backend resolution, load balancing, failover, alias fallback, and the dynamic routing policy fragments. | Changes to `llm-policy-fragments.*`, `llm-backend-pools.bicep`, routing/target policies. | `bicep/infra/modules/apim` |
| **`backend-contract-version`** | The shape of the **backend configuration contract** (`llmBackendConfig`) consumed during onboarding — backend types, auth types, model object properties, circuit breaker defaults. | Changes to the `llmBackendConfig` schema or `llm-backend-onboarding` parameter surface. | `bicep/infra/llm-backend-onboarding` |
| **`access-contract-version`** | The shape of the **Citadel Access Contract** — product policies, JWT/subscription access patterns, per-use-case product definitions, and the access-contract parameter surface. | Changes to `citadel-access-contracts` schema, product policy templates, or access-pattern behavior. | `bicep/infra/citadel-access-contracts` |
| **`gateway-upgrade-version`** | The in-place **APIM Gateway Upgrade** tooling used to update an existing gateway without re-provisioning. Currently `-preview`. | Changes to `bicep/infra/apim-gateway-upgrade`. | `bicep/infra/apim-gateway-upgrade` |
| **`usage-ingestion-version`** | The **usage ingestion pipeline** — Logic App workflows and the usage-ingestion Function that process usage/log streams into the reporting store. | Changes to `src/usage-ingestion-logicapp`, the usage-ingestion function, or the ingestion data contract. | `src/usage-ingestion-*` |

> [!TIP]
> The tracks are intentionally decoupled. When evaluating an upgrade, compare **each** track against
> what you currently run — a `usage-ingestion-version` bump has no bearing on your routing config,
> and vice versa.

---

## Runtime Version Endpoint

The deployed version manifest is exposed at runtime through the **Release Version API** in API
Management, so operators and consumers can confirm exactly which release a gateway is running
**without** inspecting the deployment source.

- **API:** `Release Version API` (`release-version-api`)
- **Path:** `GET /version`
- **Auth:** anonymous by default (no subscription key required) — a health/version-style endpoint
- **Response:** the verbatim contents of `release.json` as `application/json`

```bash
curl https://<your-apim-gateway-host>/version
```

The endpoint is served entirely from an APIM **mock (`return-response`)** policy — the release
manifest is embedded into the operation policy at deploy time, so there is no backend dependency and
no latency cost.

### How it gets created / updated

| Deployment | Behavior |
|------------|----------|
| **Primary accelerator** (`bicep/infra/main.bicep` → `apim.bicep`) | Creates the Release Version API automatically with the content of `release.json` at deploy time. |
| **APIM Gateway Upgrade** (`bicep/infra/apim-gateway-upgrade/main.bicep`) | Creates **or** updates the Release Version API (toggle `updateReleaseVersionApi`, default `true`) so the endpoint always reflects the currently deployed manifest. |

Both paths use the same shared module — `bicep/infra/modules/apim/version-api.bicep` — which reads
`release.json` via `loadTextContent` relative to the module. Bump the manifest, redeploy (or run the
gateway upgrade), and the `/version` endpoint reflects the new values.

---

## Bumping a Version

1. **Identify the affected track(s).** Only bump tracks whose component actually changed.
2. **Choose the SemVer increment** (MAJOR / MINOR / PATCH) based on the impact rules above.
3. **Bump `master-version`** whenever any track changes in a release that consumers should cite.
4. **Update [`release.json`](../release.json)** with the new values.
5. **Publish the new release.** For an **existing** hub, run the **[APIM Gateway Upgrade](../bicep/infra/apim-gateway-upgrade/README.md)**
   with the relevant feature toggles enabled — this is the standard upgrade path and updates the
   `/version` manifest in place. Only the very **first** implementation uses the primary
   `main.bicep` deployment.
6. **Validate** with `curl https://<gateway-host>/version`.

---

## Migration Strategy

### The upgrade model: initial deployment vs. release upgrades

The accelerator has two distinct lifecycle phases:

| Phase | Tooling | When |
|-------|---------|------|
| **Initial implementation** | Primary deployment — `bicep/infra/main.bicep` (`azd provision`) | Once, to stand up the hub and its landing-zone infrastructure. |
| **Release upgrades** | **[APIM Gateway Upgrade](../bicep/infra/apim-gateway-upgrade/README.md)** — `bicep/infra/apim-gateway-upgrade/main.bicep` | Every subsequent move to a new accelerator release. |

After the hub is live, **all version upgrades flow through the APIM Gateway Upgrade submodule.** It
targets an existing APIM instance and applies the new release's policies, APIs, backends, policy
fragments, named values, diagnostics, and the `/version` manifest **without re-provisioning** the
APIM service or surrounding infrastructure. Its feature toggles (e.g. `updateLLMPolicyFragments`,
`updateLLMBackends`, `updateUnifiedAiApi`, `updateReleaseVersionApi`) let you scope the upgrade to
exactly the tracks that changed.

How you migrate then depends on **which track** changed and **whether the increment is MAJOR**.

### Non-breaking (MINOR / PATCH) on any track

Adopt directly by running the **APIM Gateway Upgrade** with the relevant feature toggles enabled. No
consumer changes are required.

### `routing-version` (MAJOR)

Routing changes affect how requests reach backends (pool composition, model resolution, failover).

- Roll out to a **non-production** gateway first and run the routing/backends validation notebooks.
- Prefer the **APIM Gateway Upgrade** to update policy fragments and backend pools in place
  (`updateLLMPolicyFragments`, `updateLLMBackendPools`, `updateLLMBackends`).
- Verify load balancing, failover, and alias fallback behavior before promoting to production.

### `backend-contract-version` (MAJOR)

The `llmBackendConfig` schema changed (for example a renamed/removed property or a new required
field).

- Update your backend parameter file(s) to the new contract **before** deploying — a stale config
  against a new contract can fail validation or route incorrectly.
- Consult [LLM Backend Onboarding](../bicep/infra/llm-backend-onboarding/README.md) for the current
  schema, then re-run onboarding.

### `access-contract-version` (MAJOR)

The Citadel Access Contract product/policy surface changed.

- Review each Access Contract parameter file against the new schema.
- Re-deploy the access contracts; validate JWT and subscription access patterns per use case with
  the access-contract validation notebooks.
- See [AI Citadel Access Contracts](../bicep/infra/citadel-access-contracts/README.md).

### `gateway-upgrade-version` (`-preview`)

The in-place upgrade tooling is evolving.

- Pin to the exact version you validated. Read the
  [APIM Gateway Upgrade Guide](../bicep/infra/apim-gateway-upgrade/README.md) release notes before
  adopting a newer upgrade tool.
- For the first run against an existing/legacy gateway, enable as many feature toggles as possible
  in a **non-production** environment to detect drift early (see the upgrade guide).

### `usage-ingestion-version` (MAJOR)

The ingestion workflows or data contract changed (for example a new field in the usage record or a
changed store schema).

- Update the Logic App / Function first, then confirm downstream reporting (Cosmos/Power BI) still
  reads correctly.
- Because ingestion is decoupled from the gateway data plane, this migration can typically be
  performed independently and without gateway downtime.

### General guidance

- **Migrate one MAJOR track at a time** where possible, to isolate risk and simplify rollback.
- **Always validate in non-production first**, then promote.
- **Record the deployed `master-version`** (e.g. from the `/version` endpoint) in your change log so
  you can correlate incidents with the exact release.

---

## Related Guides

- [APIM Gateway Upgrade Guide](../bicep/infra/apim-gateway-upgrade/README.md)
- [LLM Backend Onboarding](../bicep/infra/llm-backend-onboarding/README.md)
- [AI Citadel Access Contracts](../bicep/infra/citadel-access-contracts/README.md)
- [Resiliency Guide](./resiliency-guide.md)

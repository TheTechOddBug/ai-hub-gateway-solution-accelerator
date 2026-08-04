# Publish Contract Guide

The **Publish Contract** is the mechanism the Citadel Governance Hub uses to onboard and publish centrally protected AI assets — **Tools (MCP)** and **Agents (A2A)** — through the AI Hub Gateway (Azure API Management). It complements the two existing contracts:

| Contract | Answers | Artifact |
| --- | --- | --- |
| **Backend Contract** | *Where* do LLM requests route to? | `bicep/infra/llm-backend-onboarding/` |
| **Access Contract** | *Who* may access an AI asset and under what limits? | `bicep/infra/citadel-access-contracts/` |
| **Publish Contract** (this) | *What* AI assets (tools/agents) are published and protected? | `bicep/infra/citadel-publish-contracts/` |

> **Publishing vs. access.** The Publish Contract establishes the asset: endpoints, per-asset backends, baseline policies, usage tracking, and optional API Center registration. **Granting access** is the job of the [Access Contract](../citadel-access-contracts/), which now governs published Tools/Agents alongside LLMs — a single product can grant a mix of asset types (prefix `MULTI-`) and applies **conditional per-asset-type** policies (model RBAC + token limits for LLM; request-based rate limits for Tools/Agents). Publishing itself does **not** create APIM Products/Subscriptions.

---

## 1. Concepts

A **published asset** is a governed entry point on the primary gateway. Publishing an asset creates:

1. An APIM API of the appropriate type (`mcp` or `a2a`).
2. For remote MCP / A2A: a dedicated APIM **backend** with a circuit breaker and credential injection.
3. A **baseline policy** that layers the gateway's shared governance fragments (authentication, usage metrics, alerting) onto the asset.
4. Optionally, an **Azure API Center** registration for discoverability.

Assets are declared as entries in the `publishAssets` array of a `.bicepparam` file — one file can publish many assets.

### Asset types

| `assetType` | Description | APIM type | Gateway endpoint | Backend |
| --- | --- | --- | --- | --- |
| `mcp-from-api` | Wrap selected operations of an **existing onboarded REST API** as MCP tools | `mcp` (`mcpTools[]`) | `{gateway}/{path}/mcp` | Reuses the source API's backend |
| `mcp-existing` | Publish an **existing/remote MCP server** (e.g. `https://learn.microsoft.com/api/mcp`) | `mcp` (`backendId` + `mcpPropperties`) | `{gateway}/{path}` | Dedicated `<name>-backend` |
| `a2a` | Publish a native **A2A agent** endpoint + agent card (e.g. a Foundry-hosted agent) | `a2a` (`a2aProperties` + `jsonRpcProperties`) | `{gateway}/{path}` (card at `/.well-known/agent.json`) | Policy MI auth to backend (no backend object, see §4); optional subscription-key on the client |

> **MCP endpoint suffix (important):** APIM appends `/mcp` to the path **only** for API→MCP tools (`mcp-from-api`) — e.g. `path: 'weather-tool-mcp'` → `{gateway}/weather-tool-mcp/mcp`. For a native/remote MCP server (`mcp-existing`) APIM does **not** append `/mcp` — the endpoint is `{gateway}/{path}` exactly (e.g. `{gateway}/ms-learn-tool-mcp`). Point MCP clients at these URLs accordingly.

---

## 2. Parameter schema

Global parameters (see [main.bicepparam](./main.bicepparam)):

| Parameter | Purpose |
| --- | --- |
| `apim` | `{ subscriptionId, resourceGroupName, name }` of the target gateway |
| `managedIdentityClientId` | UAMI client id for managed-identity backends (empty = system-assigned) |
| `configureCircuitBreaker` | Master toggle for backend circuit breakers (default `true`) |
| `circuitBreakerDefaults` | Default breaker settings, shallow-merged with per-asset overrides |
| `ensureUsageFragments` | Create the `mcp-usage` / `a2a-usage` fragments if missing (default `true`) |
| `apiCenter` | `{ subscriptionId, resourceGroupName, serviceName, workspaceName }` — required only if any asset opts into API Center |
| `publishAssets` | The array of assets to publish |

### Per-asset fields

Common: `assetType`, `name`, `displayName`, `description`, `path`, `metadata`, `policyXml?`, `publishToApiCenter?`, `apiCenter?`.

**`metadata`** (informational governance context surfaced to operators / API Center):

```bicep
metadata: {
  version: '1.0.0'
  owner: 'Platform Engineering'
  contactEmail: 'ai-platform@contoso.com'
  compliance: [ 'GDPR' ]        // regulatory/compliance tags
  classification: 'confidential' // public | internal | confidential
}
```

**`mcp-from-api`**: `sourceApiName`, `operationNames`, `subscriptionRequired` (default `true`), `subscriptionKeyHeaderName` (`api-key` default, or `Ocp-Apim-Subscription-Key`).

**`mcp-existing`**: `transportType` (default `streamable`), `subscriptionRequired` (default `true`), `subscriptionKeyHeaderName` (`api-key` default, or `Ocp-Apim-Subscription-Key`), `backend { url, authType, authConfig?, circuitBreaker? }`.

**`a2a`**: `agentId`, `agentCardPath` (default `/.well-known/agent.json`), `agentCardBackendUrl`, `jsonRpcPath` (default `/`), `subscriptionRequired` (default `false`), `subscriptionKeyHeaderName` (`api-key` default, or `Ocp-Apim-Subscription-Key`), `backend { url, authType, authConfig? }`.

> **A2A client auth:** set `subscriptionRequired: true` to require an APIM subscription (API) key on the caller. The key is read from the header named by `subscriptionKeyHeaderName` — use `api-key` to match the LLM/MCP convention, or `Ocp-Apim-Subscription-Key` for the APIM-native header (query-string key name is `api-key` / `subscription-key` respectively). Leave `subscriptionRequired: false` for an anonymous endpoint. The gateway still authenticates to the backend (Foundry) agent with its managed identity regardless.

### Backend auth (`backend.authType`)

| `authType` | Use | `authConfig` |
| --- | --- | --- |
| `none` | Public remote MCP | — |
| `managed-identity` | Foundry A2A, Azure-hosted backends | `{ resource }` (e.g. `https://ai.azure.com`) |
| `api-key-header` | Remote server keyed by a header | `{ headerName?, namedValueKey, keyVaultSecretUri? | secretValue? }` |
| `api-key-bearer` | Bearer-token server | `{ namedValueKey, keyVaultSecretUri? | secretValue? }` (store the full `Bearer ...` value) |

API keys are stored as APIM **named values** — prefer `keyVaultSecretUri` (rotatable, auditable) over inline `secretValue`.

---

## 3. Resiliency

**Remote MCP** assets create a dedicated APIM backend with a native **circuit breaker**, reusing the Backend Contract model:

```bicep
backend: {
  url: 'https://remote-mcp.contoso.com/mcp'
  authType: 'none'
  circuitBreaker: {          // optional per-asset override
    failureCount: 5
    failureInterval: 'PT1M'
    tripDuration: 'PT30S'
    acceptRetryAfter: true
  }
}
```

Defaults (from `circuitBreakerDefaults`): trip after **3** failures within **PT5M**, stay open **PT1M**, honor upstream `Retry-After`, on status `429` and `500–503`. Set `configureCircuitBreaker=false` to disable globally, or `backend.circuitBreaker.enabled=false` per asset. See the [resiliency guide](../../../guides/resiliency-guide.md) for the wider gateway resiliency model.

> **A2A assets** authenticate to the backend in policy against a full URL (see §4), so they do **not** create an APIM backend object and have no native circuit breaker. Add resilience for agents with a retry policy (custom `policyXml`) if needed.

---

## 4. Policies & reuse of LLM capabilities

Each asset gets a **baseline policy** ([baseline-mcp-policy.xml](./policies/baseline-mcp-policy.xml) / [baseline-a2a-policy.xml](./policies/baseline-a2a-policy.xml)) that composes the gateway's shared fragments:

- **MCP** — `security-handler` (API key + optional per-product JWT), `mcp-usage` (metric), `raise-alert-events` (opt-in alerting).
- **A2A** — `authentication-managed-identity` (backend/Foundry auth, injected with the asset's MI client id), `a2a-usage` (metric), `raise-alert-events`. **No `security-handler`** — see the A2A auth model below.

The MCP fragments are the **same** ones used by the LLM APIs, so existing governance composes with published tools. To layer more controls on a specific asset (e.g. inbound PII anonymization or content safety), supply a custom `policyXml` on that asset rather than editing the baseline.

### A2A authentication model (important)

APIM's A2A preview **does not validate product/subscription keys** — sending an `api-key` header to an A2A endpoint re-triggers a broken subscription gate and returns `401`. Therefore, in **phase 1**:

- The A2A endpoint is **anonymous at the gateway** (`subscriptionRequired: false`); client-side auth (subscription/JWT) is added by the **phase-2 Access Contract**.
- The gateway authenticates to the **agent backend** (Foundry) using a **managed identity** — attached in the policy via `<authentication-managed-identity resource="https://ai.azure.com" client-id="…"/>`, injected from `managedIdentityClientId`. The MI must hold **Foundry Agent Consumer** (or **Azure AI User**) on the Foundry project.
- Because auth is done in policy against a **full backend URL**, A2A assets do **not** create an APIM backend object (and thus have no native circuit breaker — see §3). MCP assets are unaffected.

### ⚠️ MCP streaming constraint

MCP servers use a streaming (SSE) transport. **Policies must not read `context.Response.Body`** for MCP assets — doing so buffers the response and breaks the transport. Consequently:

- Request-side controls (auth, usage, inbound PII/content-safety) **work** for MCP.
- Response-side controls (PII **de**-anonymization, response content-safety) are **not supported** for MCP.

A2A v1.0 is JSON-RPC (non-streaming), so response-side inspection is generally safe there — but the baseline keeps it opt-in for simplicity.

---

## 5. Usage tracking

Usage is emitted as **App Insights custom metrics** (no Event Hub, no `log-to-eventhub`), mirroring the LLM metric approach:

| Metric | Namespace | `deploymentName` dim | `customDimension1` | `customDimension2` |
| --- | --- | --- | --- | --- |
| `McpRequests` | `mcp-usage` | tool / MCP name | `mcp` | operation |
| `A2ARequests` | `a2a-usage` | agent name | `a2a` | operation |

Two scheduled **Logic App** workflows aggregate these metrics into Cosmos DB, cloned from the LLM usage workflow:

| Workflow | Reads metric | Writes container | Export-config id |
| --- | --- | --- | --- |
| `src/usage-ingestion-logicapp/mcp-usage-ingestion` | `McpRequests` | `mcp-usage-container` | `003` |
| `src/usage-ingestion-logicapp/agent-usage-ingestion` | `A2ARequests` | `agent-usage-container` | `004` |

Each run queries `customMetrics` over a rolling window (`sum(valueSum)` = request count), upserts one document per `(tool/agent, product, backend, hour)` bin, and advances `lastExportDate` in the `streaming-export-config` container. The Logic App's existing `azuremonitorlogs` connection and managed-identity RBAC (Azure Monitor Logs Reader + Cosmos SQL Contributor) are reused unchanged. The two new containers are added to the Cosmos module.

---

## 6. API Center registration (optional)

Set `publishToApiCenter: true` and provide the global `apiCenter` coordinates plus a per-asset `apiCenter` block:

```bicep
publishToApiCenter: true
apiCenter: {
  environmentName: 'mcp-dev'          // mcp-dev | mcp-prod | api-dev | ...
  lifecycleStage: 'development'
  versionName: '1-0-0'
  customProperties: { Visibility: true, Vendor: 'Internal', Type: 'AI Gateway' }
}
```

The asset is registered (kind `mcp` or `a2a`) via the shared `api-center-onboarding` module. Off by default.

---

## 7. Publishing a Foundry agent as A2A

Foundry-hosted agents can be exposed as A2A endpoints. Before publishing:

1. **Enable incoming A2A** on the agent (a prompt agent, or a hosted agent that implements the responses protocol) via a `PATCH` to `…/agents/{agent}?api-version=v1` setting the `agent_card` and `protocol_configuration { responses: {}, a2a: {} }`. See [Enable incoming A2A on a Foundry agent](https://learn.microsoft.com/en-us/azure/foundry/agents/how-to/enable-agent-to-agent-endpoint) and the sample [a2a-foundry-sample-agent.ps1](../../../local/contracts/a2a-foundry-sample-agent.ps1).
2. **Grant the gateway's managed identity** access on the Foundry project. Incoming A2A requires Microsoft Entra auth (key-based auth is not supported), so the identity APIM uses to call the agent needs a data-plane role on the project (`Azure AI User`, or the least-privilege `Foundry Agent Consumer`). Prefer APIM's **user-assigned** managed identity and pass its **`clientId`** as the global `managedIdentityClientId` parameter — the A2A backend then embeds managed-identity auth (audience `https://ai.azure.com`) using that specific identity. The validation notebook automates both the grant and the `clientId` wiring (step 3️⃣.1).

Then configure the asset:

```bicep
{
  assetType: 'a2a'
  name: 'hr-chat-agent'
  displayName: 'HR Chat Agent (A2A)'
  path: 'hr-chat-agent'
  agentId: 'HR-ChatAgent'
  subscriptionRequired: true        // require an APIM subscription key on the caller
  subscriptionKeyHeaderName: 'api-key'  // or 'Ocp-Apim-Subscription-Key'
  agentCardPath: '/.well-known/agent.json'
  agentCardBackendUrl: 'https://{account}.services.ai.azure.com/api/projects/{project}/agents/{agent}/endpoint/protocols/a2a/agentCard/v1.0'
  jsonRpcPath: '/'
  backend: {
    url: 'https://{account}.services.ai.azure.com/api/projects/{project}/agents/{agent}/endpoint/protocols/a2a'
    authType: 'managed-identity'
    authConfig: { resource: 'https://ai.azure.com' }
  }
}
```

APIM re-exposes the Foundry agent card (served at the custom `agentCard/v1.0` path) at the standard `/.well-known/agent.json` path, and proxies JSON-RPC calls to the Foundry A2A base path. The gateway authenticates to Foundry with the **user-assigned managed identity** whose `clientId` you pass as `managedIdentityClientId` (that identity needs **Foundry Agent Consumer** on the project).

**Agent card transport rewrite.** A2A SDK / Microsoft Agent Framework clients read the agent card's transport **interface URLs** to decide where to send requests. Foundry's card advertises the Foundry endpoint, which would make clients bypass the gateway and call Foundry directly. So `publishA2aAgent.bicep` adds an **outbound policy** that rewrites the backend (Foundry) transport URLs in the card to the **gateway** A2A URL (`{gateway}/{path}`). The rewrite is guarded to JSON responses (the card), so it never buffers a streaming body. The inbound policy also forces `Accept-Encoding: identity` on the backend request, because `find-and-replace` cannot rewrite a gzip-compressed card body (a compressed card returns empty and clients fail to resolve it). Result: clients that resolve the card — including `agent_framework.a2a.A2AAgent` — route **through the gateway** (presenting their subscription key when `subscriptionRequired: true`), keeping the traffic governed, regardless of the client's compression settings.

> **Foundry A2A notes:** v1.0 is **JSON-RPC only**, **text-only**, **no streaming**, and in **preview**; Foundry serves **v0.3 by default** (send `A2A-Version: 1.0` to select v1.0, and note the message object needs a `kind` field). Client access is **subscription-key based**: publish with `subscriptionRequired: true` and callers present a valid APIM subscription key in the header named by `subscriptionKeyHeaderName` (`api-key` or `Ocp-Apim-Subscription-Key`); publish with `subscriptionRequired: false` for an anonymous endpoint. Richer client auth (JWT, product scoping) is added by the phase-2 Access Contract.

---

## 8. Validation

`validation/citadel-publish-contract-tests.ipynb` deploys and validates all three asset types end-to-end (MCP handshake, agent-card fetch, JSON-RPC call, policy application, usage metrics, and circuit-breaker resiliency). See that notebook for a runnable scenario.

---

## 9. Related

- [Access Contract](../citadel-access-contracts/README.md)
- [Backend Contract](../llm-backend-onboarding/README.md)
- [Resiliency guide](../../../guides/resiliency-guide.md)
- [Platform observability guide](../../../guides/platform-observability-guide.md)

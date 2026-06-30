# Option A — MI-swap (identity-enforced no-bypass)

> Part of [Governed GitHub Copilot → Private Foundry via APIM](../README.md). This is **Option A**:
> APIM swaps the developer's token for its **own managed identity** to call Foundry, so **identity**
> makes the gateway non-bypassable. For the
> network-enforced alternative (developer-identity pass-through to a **private** Foundry), see
> [`infra-passthrough/`](../infra-passthrough/README.md).

A proof of concept that lets developers use **our own Azure AI Foundry model inside GitHub
Copilot**, while enforcing four things that don't come together out of the box:

1. **Entra-only auth, no API keys** — developers never hold a model key.
2. **Per-user authorization** — only members of an approved security group may use it.
3. **Central governance** — per-developer token limits + usage metering for cost/audit.
4. **No bypass** — the model can only be reached through our gateway.

We achieve this by putting **Azure API Management (APIM)** between Copilot and Foundry. APIM
authenticates the developer, checks their group membership, meters/limits their usage, then calls
Foundry using **its own managed identity**. Foundry trusts *only* APIM's identity, so a developer
can't point their client straight at Foundry.

> **Scope note:** This PoC intentionally **skips private networking** to stay simple — Foundry is
> public (`publicNetworkAccess = Enabled`). See [Production hardening](#production-hardening) for how
> you'd lock the network down later.

---

## The core idea: two identities, two tokens

| Token | Minted by | Audience | Used for |
|---|---|---|---|
| Developer token | the laptop (`az login` / VS Code sign-in) | `https://cognitiveservices.azure.com` | APIM answers *"who is this, and are they allowed?"* |
| APIM managed-identity token | Azure, for APIM | Foundry / Microsoft Graph | what actually calls Foundry (and reads group membership) |

APIM validates the developer's token, then discards it and substitutes its own to call the backend.
Developers have no RBAC role on Foundry — only APIM does — which is what forces every request through the
gateway.

---

## Architecture

```mermaid
flowchart TB
    Dev["👩‍💻 Developer<br/>VS Code Copilot (keyless BYOK)"]
    Entra["🔑 Microsoft Entra ID<br/>(issues tokens, holds the group)"]
    Graph["📇 Microsoft Graph"]
    AppI["📊 One Log Analytics workspace<br/>App Insights token metrics + gateway served-model logs"]

    subgraph APIM["🛡️ Azure API Management — Basic v2 (system-assigned managed identity)"]
        direction TB
        P1["1 · validate-azure-ad-token<br/>tenant + aud=cognitiveservices → else 401"]
        P2["2 · group check via Graph<br/>list group members, filter by oid (cached 1h) → else 403"]
        P3["3 · llm-token-limit + emit-token-metric + copilot-finops trace<br/>keyed on developer oid → else 429"]
        P4["4 · swap to APIM's MI token<br/>set Authorization, forward"]
        P1 --> P2 --> P3 --> P4
    end

    Foundry["🤖 Azure AI Foundry — gpt-4.1<br/>key auth disabled · RBAC: only APIM's MI"]

    Dev -->|"a · get developer token (DefaultAzureCredential)"| Entra
    Entra -->|"developer token"| Dev
    Dev -->|"b · POST /foundry/openai/v1/chat/completions<br/>Authorization: Bearer (developer token)"| P1
    P2 -.->|"is dev in copilot-users?"| Graph
    P4 -->|"c · request + APIM MI token"| Foundry
    P3 -.->|"token usage"| AppI
    Foundry -->|"completion"| Dev
```

### Request lifecycle (sequence)

```mermaid
sequenceDiagram
    participant Dev as VS Code Copilot
    participant Entra as Entra ID
    participant APIM as APIM gateway
    participant Graph as MS Graph
    participant F as Foundry (gpt-4.1)

    Dev->>Entra: sign in → token for "cognitiveservices"
    Entra-->>Dev: developer token (contains user's oid)
    Dev->>APIM: POST /foundry/openai/v1/chat/completions + Bearer(dev token)
    APIM->>APIM: 1) validate token (tenant + audience) — else 401
    APIM->>Graph: 2) is oid a member of copilot-users? (using APIM's MI token, cached 1h)
    Graph-->>APIM: yes / no — if no → 403
    APIM->>APIM: 3) under per-user tokens/min? else 429, then emit usage metric
    APIM->>APIM: 4) drop dev token, attach APIM's MI token
    APIM->>F: forward request (Bearer = APIM MI token)
    F-->>APIM: chat completion (+ token usage)
    APIM-->>Dev: completion
```

### Why it can't be bypassed

```mermaid
flowchart LR
    D["👩‍💻 Developer token"] -->|"direct call"| F["🤖 Foundry"]
    F -->|"401 — dev has no RBAC role"| D
    A["🛡️ APIM managed identity"] -->|"has 'Cognitive Services OpenAI User'"| F
    F -->|"200"| A
    style F fill:#222,color:#fff
```

Only APIM's managed identity holds a role on Foundry. A developer calling Foundry directly is
rejected (`401`), so the gateway — with its auth, group check, and limits — is the only way in.

---

## Components

| Component | Name (this PoC) | Role |
|---|---|---|
| Copilot client | VS Code `azure` BYOK vendor | Acquires the developer's Entra token; sends requests to APIM |
| Entra ID | tenant `<tenant-id>` | Issues developer + APIM tokens; holds the `copilot-users` group |
| APIM | `apim-copilot-poc` (Basic v2) | The gateway: validate → authorize → meter/limit → MI-swap → forward |
| Microsoft Graph | (first-party) | Answers the group-membership question |
| Foundry | `cog-copilot-poc` / `gpt-4.1` | Hosts the model; trusts only APIM's MI; key auth disabled |
| App Insights | `appi-copilot-poc` | Receives per-`oid` token metrics for dashboards/chargeback |

**Gateway URL:** `https://apim-copilot-poc.azure-api.net/foundry/openai/v1/chat/completions`

---

## Identity & permissions

APIM's managed identity (the `apim-copilot-poc` "enterprise application" in Entra) is granted access
in **two completely separate systems**:

```mermaid
flowchart TB
    MI["🪪 APIM managed identity<br/>(enterprise app: apim-copilot-poc)"]

    subgraph RBAC["Azure RBAC — 'what can it do to Azure resources?'<br/>(lives on the Foundry resource's Access control / IAM)"]
        R1["Role: Cognitive Services OpenAI User<br/>scope: the Foundry account"]
    end

    subgraph GRAPHPERM["Graph application permission — 'what can it read in the directory?'<br/>(an appRoleAssignment on Microsoft Graph)"]
        G1["GroupMember.Read.All<br/>(lets it list group members)"]
    end

    MI --> RBAC
    MI --> GRAPHPERM
    RBAC --> Foundry["🤖 Foundry — run the model"]
    GRAPHPERM --> Graph["📇 Graph — check group membership"]
```

- **Azure RBAC** (step 5 in `deploy.sh`) → call the model. Granted on the **Foundry resource**.
- **Graph app permission** (step 6) → read group membership. Granted as an **appRoleAssignment** on
  Microsoft Graph, admin-consented.

These are why the same identity shows its grants in two different places in the portal.

---

## Repository layout

This folder (`infra/`) holds **Option A**:

```
infra/
├── deploy.sh                      # one-shot reproducible deploy (heavily commented)
├── apim.json                      # ARM template: APIM Basic v2 + system-assigned MI
├── apim-policy.xml                # the inbound gate (auth → group → limit/meter → MI swap)
├── test-gateway.sh                # end-to-end validation via curl (device-code; see note on MFA)
├── copilot-cli.env.sh             # Copilot CLI BYOK env
└── chatLanguageModels.snippet.json# VS Code BYOK model entry to paste
└── README.md                      # this file
```

Repo root: [`README.md`](../README.md) (overview of both options) · [`infra-passthrough/`](../infra-passthrough/README.md) (Option B) · [`plan.md`](../plan.md) (original design write-up).

---

## Deploy it

```bash
az login              # as a subscription Owner who is also an Entra admin
bash infra/deploy.sh  # ~5–10 min (APIM provisioning dominates)
```

`deploy.sh` is commented step-by-step. In short it: creates the RG → Foundry + `gpt-4.1` → App
Insights → APIM (Basic v2 + managed identity) → grants the MI access to Foundry (RBAC) and Graph
(group read) → defines the API with no subscription key → wires App Insights → applies the policy.

**Tear it down:** `bash infra/cleanup.sh` (deletes the RG + purges the soft-deleted Foundry/APIM;
add `-y` to skip the confirmation prompt).

---

## Use it from VS Code Copilot

1. Add this to `%APPDATA%\Code\User\chatLanguageModels.json` (also in
   `infra/chatLanguageModels.snippet.json`):

   ```json
   {
     "name": "Foundry-via-APIM",
     "vendor": "azure",
     "models": [
       {
         "id": "gpt-4.1",
         "name": "gpt-4.1 (governed)",
         "url": "https://apim-copilot-poc.azure-api.net/foundry/openai/v1/chat/completions",
         "toolCalling": true, "vision": true,
         "maxInputTokens": 128000, "maxOutputTokens": 16000
       }
     ]
   }
   ```
2. In Copilot Chat → **model picker → Manage Models → Azure**, leave the **API key blank** (keyless
   Entra). Sign in as a user **in the `copilot-users` group**.
   - To switch the account it uses without signing others out: **Extensions view → GitHub Copilot
     Chat → gear → Account Preferences**.
3. Select **"gpt-4.1 (governed)"** and chat. (Inline grey-text completions stay GitHub-hosted — only
   chat/agent traffic is governed; this is expected.)

---

## Adding models, the model router, and the Responses API

The gateway is model-agnostic — one APIM operation carries any model (the client picks via the request
body's `model` field), and the policy keys on the *user*, not the model. So:

- **More models** — deploy another model in the same Foundry account; it flows through the same gateway
  with no APIM changes. Just add a VS Code entry with the new deployment name.
- **Model router** (`model-router`, deployed here) — a single deployment that auto-selects the underlying
  model per prompt. Call it with `"model": "model-router"`; each response's `model` field reveals which
  model actually answered (we've seen `gpt-5-nano`, `gpt-5-mini`, `gpt-5.4-mini`, `gpt-oss-120b`, …).
- **Responses API** — exposed at `/foundry/openai/v1/responses` (same gate applies). For the VS Code
  `azure` vendor, Responses is cleanest via the Copilot CLI/SDK `wire_api: responses` or a custom
  endpoint; plain chat uses `/chat/completions`.

### ⚠️ The model-router endpoint split (and how the gateway absorbs it)

model-router serves its two APIs on two different Azure endpoints (verified, and matching Microsoft's own
SDK `AIProjectClient.get_openai_client()`):

| model-router via… | `/chat/completions` | `/responses` |
|---|---|---|
| Classic **data plane** (`…openai.azure.com`, aud `cognitiveservices`) | ✅ | ❌ 400 |
| Foundry **project** endpoint (`…/api/projects/…`, aud `ai.azure.com`) | ❌ 401 | ✅ |

Named models (e.g. `gpt-4.1`) work on **both**; only `model-router` is split. This mirrors Microsoft's
own docs, whose [model-router how-to](https://learn.microsoft.com/azure/foundry/openai/how-to/model-router#test-model-router-with-foundry-responses-and-chat-completions)
shows Responses via the **`AIProjectClient`** (project endpoint) and Chat Completions via the
**`AzureOpenAI`** client (data-plane endpoint) — two different clients/endpoints, one per API.

**The gateway handles it with path-based routing** (policy step 4): requests to `…/responses` go to
the **project** backend (MI audience `ai.azure.com`); everything else goes to the **data-plane**
backend (MI audience `cognitiveservices`). Result — `model-router` works on **both** chat and
Responses through the one governed endpoint (validated: all four combos return 200). Requires a
**Foundry project** (`copilot-proj`, created by `deploy.sh`) and the APIM MI to hold **Cognitive
Services User** (for the project/`ai.azure.com` hop) in addition to **Cognitive Services OpenAI User**.

Per-request metering carries a `model` dimension for per-model breakdowns (and `oid` for per-developer
chargeback). For `model-router` that dimension is the *requested* name; the served model is captured by
the `GatewayLlmLogs` diagnostic and tied to the developer by the inbound `copilot-finops` trace (same
`CorrelationId`), so the FinOps dashboard attributes the routed model per developer. App Insights and the
gateway logs share one workspace (`law-copilot-poc`); see `finops/README.md`.

## Using the GitHub Copilot CLI (BYOK)

The [Copilot CLI](https://docs.github.com/copilot) (`npm i -g @github/copilot`) drives the gateway in BYOK
mode — no GitHub login required. It's env-var driven (`infra/copilot-cli.env.sh`).

**Keyless (recommended).** Use the `azure` provider with no token set — the CLI acquires the Entra token
itself via `DefaultAzureCredential` (scope `https://cognitiveservices.azure.com/.default`, exactly our
gateway's audience), picking up `az login`, a managed identity, or a service principal. Nothing to paste
or refresh.

```bash
az login   # as a copilot-users member
export COPILOT_PROVIDER_BASE_URL="https://apim-copilot-poc.azure-api.net/foundry/openai/v1/"
export COPILOT_PROVIDER_TYPE="azure"
export COPILOT_PROVIDER_WIRE_API="completions"
export COPILOT_MODEL="model-router"     # or gpt-4.1
copilot -p "explain this repo" --allow-all-tools
```

> ⚠️ Leave `COPILOT_PROVIDER_AZURE_API_VERSION` unset — setting it flips the CLI to the classic
> `…/deployments/<name>/…?api-version=…` format, which doesn't match our `/openai/v1/*` route → `404`.

**Pasted bearer (any client).** The gateway is an OpenAI-compatible endpoint behind `Authorization: Bearer
<token>`, so any client that sets a base URL + bearer works. Mint a token as a copilot-users member
(`az account get-access-token --resource https://cognitiveservices.azure.com --query accessToken -o tsv`);
for the CLI that's `COPILOT_PROVIDER_TYPE="openai"` + `COPILOT_PROVIDER_BEARER_TOKEN`. It expires in
~60–90 min and doesn't refresh, so prefer the keyless path. Either way an out-of-group token gets `403`,
identical to VS Code.

**Wire API.** `completions` is the universal default (every model). Use `responses` only with a reasoning
model (e.g. `gpt-5-mini`) — its agent loop sends reasoning params (`reasoning.encrypted_content`) that
non-reasoning models reject, so `gpt-4.1` and `model-router` must stay on `completions`. That's a client
constraint, not the gateway (APIM serves `/responses` for any model;
[open CLI request](https://github.com/github/copilot-cli/issues/2559)).

## Validation

`infra/test-gateway.sh` exercises the full matrix (it mints a token *as* the test user — note that
password/ROPC login is blocked by MFA in this tenant, so use the device-code flow / an interactive
sign-in). Results:

| Test | Expected | Result |
|---|---|---|
| In-group user → APIM | 200 + completion | ✅ (curl **and** VS Code Copilot) |
| Out-of-group user → APIM | 403 | ✅ |
| No token → APIM | 401 | ✅ |
| Bypass: user token straight to Foundry | 401 | ✅ |
| Exceed per-user tokens/min | 429 | ✅ |
| Per-user metering | metrics in App Insights | ✅ (token totals by `oid`) |

Query the per-user usage in App Insights:

```kusto
customMetrics
| where timestamp > ago(1d)
| where name in ('Total Tokens','Prompt Tokens','Completion Tokens')
| extend developer = tostring(customDimensions.oid), model = tostring(customDimensions.model)
| summarize tokens = sum(valueSum), requests = sum(valueCount) by developer, model, name
```

---

## Limitations & scope

None of these are gateway bugs — APIM serves both `/chat/completions` and `/responses` for any
supported model, fully governed. The constraints live in the **clients**:

| Client | Chat Completions | Responses API |
|---|---|---|
| **VS Code Copilot** (`azure` BYOK vendor) | ✅ gpt-4.1, model-router | ❌ chat-only vendor — sends `messages` + nested-`function.name` tools, so a `/responses` URL fails `400` |
| **Copilot CLI** (`completions` wire-api) | ✅ gpt-4.1, model-router | — |
| **Copilot CLI** (`responses` wire-api) | — | ✅ reasoning models only (e.g. `gpt-5-mini`) |

- **Inline (grey-text) completions stay GitHub-hosted** — only chat/agent traffic is governable via
  BYOK; this can't be redirected.
- **No private networking** — Foundry is public (`publicNetworkAccess = Enabled`); see
  [Production hardening](#production-hardening).
- **POST-only API surface** — the gateway exposes `POST /openai/v1/*`; Responses follow-up GETs
  (`/responses/{id}`) aren't wired (add a GET operation if a client needs them).

### Operational caveats

- **Streaming & token accuracy.** Metering (`llm-emit-token-metric`) records the **actual** `usage`
  from the response — accurate for normal and streamed responses alike (inaccurate only if a stream is
  interrupted, and streamed responses must carry `stream_options.include_usage=true`). Rate limiting
  (`llm-token-limit`) **estimates** tokens for streamed requests, so per-minute enforcement is
  approximate under streaming — fine for budgets; the metric itself stays exact.
- **Group-check cache (1 h).** A user removed from the group keeps access until their cache entry
  expires (tune `duration` in the policy). Resetting a token-limit block requires rotating the
  `counter-key` — raising the TPM alone doesn't clear an active back-off.
- **Least-privilege group check.** The policy authorizes by listing the group's `transitiveMembers`
  filtered by the user's `oid`, which needs only **`GroupMember.Read.All`** — not the broader
  `Directory.Read.All` that `checkMemberGroups` would require.
- **Token acquisition needs an MFA-capable flow.** Password/ROPC login is blocked by MFA in this
  tenant — use device-code or interactive sign-in.
- **Cross-tenant.** The keyless path uses the signed-in account's home tenant; it won't work for
  cross-tenant testing.

---

## Production hardening

Not done here (deliberately), but the natural next steps:

- **Private networking** — Standard v2 + VNet integration (or Premium v2 injection), Foundry private
  endpoint + private DNS, `publicNetworkAccess = Disabled`.
- **Backend pool + circuit breaker** across multiple Foundry deployments/regions.
- **Logging policy decision** — full prompt/response payloads vs. metadata only (data governance).
- **Raise limits for scale** — per-user TPM in the policy and the Foundry deployment capacity
  (the binding ceiling is `--sku-capacity`).

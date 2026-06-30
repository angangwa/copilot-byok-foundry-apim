# FinOps dashboard — per-developer Copilot usage & cost

An Azure Monitor **Workbook** that turns the gateway's per-user token metrics into a FinOps view of
**GitHub Copilot → private Foundry** spend, attributed to the individual developer. It's built for the
question that defines coding-agent cost at scale:

> **Who is actually driving the spend?** — *a small share of developers typically accounts for most of
> the cost.* The workbook makes that concentration the headline.

It reads the telemetry the APIM gateway emits — per-developer token metrics (`oid`, `developerName`,
`model`) plus the gateway's generative-AI logs that record the model the router actually served and tie it
back to the developer (the *Live routing* widgets — see [How it's tracked](#how-its-tracked)). All of it
lands in one Log Analytics workspace. It defaults to Option A (`infra/`), but `infra-passthrough/` emits
the same telemetry, so the same workbook serves both — just point the scripts at the `-pt` resources
([see below](#pointing-it-at-the-pass-through-deployment-infra-passthrough)).

## What it looks like

> Populated with the synthetic demo fleet (`seed-usage.py`) — illustrative shapes, not real spend.
> The *Live routing* tables are the exception: they show genuine gateway traffic.

Executive summary + usage concentration (KPIs, Pareto curve, top-developer leaderboard):
![Executive summary KPI tiles, the Pareto cumulative-spend curve, and the top-developer leaderboard](screenshots/01-executive-concentration.png)

Model mix + live routing (spend by model, and the served model per request × developer):
![Spend-share donut and spend-over-time-by-model area chart, with the live routing table from GatewayLlmLogs](screenshots/02-model-mix-live-routing.png)

Caching + governance (cache-hit by context band, developers near the 500k TPM limit):
![Cache-hit percentage by context band and the governance rate-limit-pressure table](screenshots/03-caching-governance.png)

Per-developer chargeback + forecast (a developer's spend by model and over time, vs an editable budget):
![Per-developer drill-down by model and spend-over-time trend, with budget and forecast tiles](screenshots/04-drilldown-forecast.png)

## What it shows

| Section | Widgets |
|---|---|
| **Executive summary** | total spend · tokens · requests · active developers · avg $/dev · blended $/1k tokens |
| **Usage concentration** | "top 5 devs / top 10% / top 20% drive X%" tiles · **Pareto curve** · top-N leaderboard · spend-distribution histogram |
| **Model mix & efficiency** | cost & tokens by model · avg tokens/request · `$/1k` per model · spend-over-time trend (selectable bucket: auto/5m/hourly/daily) · **Live routing** — real served-model vs requested deployment from `GatewayLlmLogs`, plus **per-developer × served model** (joined to the `copilot-finops` trace) |
| **Usage timing** | day-of-week × hour-of-day **heatmap** (CEST) — work-hours / weekday concentration |
| **Context window & caching** | request distribution by context band (<50k … 500k–1M) · developers by typical context · **cache-hit rate & $ saved** · **cache-hit % by context band** (long-context → more cache) |
| **Governance** | developers whose burst implies sustained throughput near the **500k TPM** per-user limit |
| **Per-developer drill-down** | pick a developer → their model breakdown and spend trend (chargeback) |
| **Budget & forecast** | run-rate projection of monthly spend vs an editable budget |

Cost is a **token × price** estimate that **discounts cached input tokens** (the gateway already emits
a `Prompt Cached Tokens` metric — no policy change needed). Prices are an **editable parameter** (USD
per 1M tokens: `inP` input, `outP` output, `cachedP` cached-input) defaulting to list-price
placeholders (cached ≈ 10–25% of input) — change them to your negotiated rates. A model with no price-table
entry falls back to a blended default.

## How it's tracked

Four gateway mechanisms feed the dashboard, all landing in one Log Analytics workspace:

| Mechanism | Runs | Lands in | Tracks |
|---|---|---|---|
| [`llm-emit-token-metric`](https://learn.microsoft.com/azure/api-management/llm-emit-token-metric-policy) | inbound | `customMetrics` (App Insights) | token counts (prompt/completion/total/cached) tagged `oid`, `developerName`, `model` — the engine behind every per-developer cost widget. |
| [`llm-token-limit`](https://learn.microsoft.com/azure/api-management/llm-token-limit-policy) | inbound | enforced inline | the per-developer 500k TPM ceiling the *Governance* view reasons about. |
| [`GatewayLlmLogs`](https://learn.microsoft.com/azure/api-management/api-management-howto-llm-logs) diagnostic | resource log | `ApiManagementGatewayLlmLog` | served model (`ModelName`) vs requested deployment (`DeploymentName`), keyed by `CorrelationId`. Token+model only — no bodies (no PII, low cost). |
| `copilot-finops` trace | inbound | `ApiManagementGatewayLogs.TraceRecords` | the developer `oid`/`developerName` on the same `CorrelationId` as the LLM log. |

The token metric runs inbound, before the response exists, so for `model-router` it records only the
requested name. The served model is in the response — and responses stream, so it can't be read in an
outbound policy without buffering. Attribution therefore happens in Log Analytics: join
`ApiManagementGatewayLlmLog` (served `ModelName`) to the `copilot-finops` trace (developer `oid`) on
`CorrelationId`. That's the *Live routing* widgets — streaming-safe, no body capture. The demo's
`seed-usage.py` writes the served model straight into `customMetrics` so the fleet charts show a routing
split, but it bypasses the gateway, so the synthetic fleet doesn't appear in the join-based widgets —
those are real traffic only.

`deploy.sh` wires this up. To enable it on an existing gateway:

```bash
APIM_ID="$(az apim show -n <apim> -g <rg> --query id -o tsv)"
# 1) route BOTH gateway log categories to the (App Insights') Log Analytics workspace.
#    GatewayLlmLogs -> served model; GatewayLogs -> the copilot-finops trace (developer oid).
#    --export-to-resource-specific true is REQUIRED: without it data lands in the legacy
#    AzureDiagnostics table, NOT the ApiManagementGateway* tables, and the widgets stay empty.
#    (First rows take ~15 min to appear.)
az monitor diagnostic-settings create --name llm-gateway-logs \
  --resource "$APIM_ID" --workspace "<log-analytics-workspace-id>" \
  --export-to-resource-specific true \
  --logs '[{"category":"GatewayLlmLogs","enabled":true},{"category":"GatewayLogs","enabled":true}]'
# 2) turn on LLM logging + 'information' verbosity for the API. logs:"enabled" = token usage +
#    served model name ONLY (omit requests/responses => no bodies => no PII). verbosity:"information"
#    makes the gateway emit the inbound copilot-finops trace into GatewayLogs.TraceRecords.
az rest --method put \
  --url "https://management.azure.com$APIM_ID/apis/<api>/diagnostics/azuremonitor?api-version=2024-05-01" \
  --headers "Content-Type=application/json" \
  --body '{"properties":{"loggerId":"'"$APIM_ID"'/loggers/azuremonitor","verbosity":"information","largeLanguageModel":{"logs":"enabled"}}}'
```

> The seeder emits **one row per request** (`valueCount==1`), exactly like real gateway traffic, so the
> request-band and cache widgets work identically on synthetic and real data. Older aggregated demo rows
> (`valueCount>1`) are automatically excluded from the per-request widgets.

## Quick start

```bash
cp ../config.env.example ../config.env     # if you haven't already (RG / app name optional overrides)
az login                                   # reader on rg-copilot-foundry-poc is enough

python3 seed-usage.py                       # 1) seed a synthetic developer fleet (see note below)
bash deploy-finops.sh                       # 2) publish the workbook (idempotent)
```

Then open **Azure portal → Monitor → Workbooks → "Copilot FinOps — per-developer usage & cost"**
(or the `appi-copilot-poc` resource → Workbooks). Adjust the **Time range**, **Models**, **Price
table** and **Budget** parameters at the top; everything recomputes live.

### Pointing it at the pass-through deployment (`infra-passthrough/`)

`infra-passthrough/` emits the same telemetry and runs the same diagnostics, so the workbook works against
it unchanged. Both `seed-usage.py` and `deploy-finops.sh` read resource names from env vars — just point
them at the `-pt` resources:

```bash
export RG=rg-copilot-foundry-poc-pt APPINSIGHTS_APP=appi-copilot-poc-pt SVC=apim-copilot-poc-pt
python3 seed-usage.py        # seed that deployment's App Insights
bash deploy-finops.sh        # publish the workbook into the -pt resource group
```

(Per-developer metering and routed-model capture are the same on both. Pass-through just doesn't support
model-router `/responses` — data-plane only — which the dashboard doesn't depend on.)

## How the demo data works (and the ingestion limit)

In a PoC there's only one real test user, so `seed-usage.py` manufactures a believable fleet (~60
developers, lognormal activity → Pareto concentration, per-developer model mix, business-hours shape) and
POSTs it to the same App Insights ingestion endpoint the gateway uses, with the same schema
(`customDimensions.oid` / `developerName` / `model`, where `model` is the served model). It adds one
synthetic-only label, `requestedModel` (`model-router`), which the real gateway records as
`GatewayLlmLogs.DeploymentName` instead. The workbook can't tell synthetic rows from real telemetry, so
real `copilotuser` traffic shows up alongside.

**Ingestion window:** the App Insights ingestion endpoint **drops any record older than ~60 minutes**
(newer rows keep their timestamp). So:

- One `seed-usage.py` run fills a rolling **~55-minute window** — enough for *every* widget except a
  long trend (concentration, leaderboards, cost and model mix don't depend on history).
- To grow a genuine **multi-day trend**, you can't backfill — you keep emitting "now". That's what the
  **heartbeat** does.

## Heartbeat — growing a real trend (optional)

`deploy-heartbeat.sh` builds the seeder image in the cloud (`az acr build`, no local Docker) and runs
it as a **scheduled Azure Container Apps Job** (default every 30 min) that emits a fresh "now" slice
each time. Leave it running for a day or two and the trend line fills out with genuine, diurnally-shaped
history. It scales to zero between runs (a few cents/day) and lives in the same resource group, so the
existing `infra/cleanup.sh` tears it down with everything else.

```bash
bash deploy-heartbeat.sh
az containerapp job start -n finops-seeder -g rg-copilot-foundry-poc   # optional: run one now
az containerapp job execution list -n finops-seeder -g rg-copilot-foundry-poc -o table
# pause but keep data:
az containerapp job update -n finops-seeder -g rg-copilot-foundry-poc --trigger-type Manual
```

## Files

| File | Purpose |
|---|---|
| `workbook.json` | The workbook definition (paste into the portal's Advanced Editor, or deploy below). |
| `workbook.template.json` | ARM template wrapping a `microsoft.insights/workbooks` resource. |
| `deploy-finops.sh` | Resolves the App Insights id, injects it, deploys the workbook (idempotent). |
| `seed-usage.py` | Synthetic per-developer usage generator (stdlib only). |
| `Dockerfile` + `deploy-heartbeat.sh` | The scheduled Container Apps Job that keeps the trend growing. |

## Caveats

- **Synthetic figures** — illustrative volumes; the *shape* (concentration, model mix) is the point,
  not the absolute dollars. Edit the **Price table** parameter for real rates.
- **Live routing is real traffic only** — the join-based per-developer served-model widgets read gateway
  logs, which the seeder can't write, so the synthetic fleet appears in the metric-based charts but not in
  *Live routing* (see [How it's tracked](#how-its-tracked)).
- **Forecast needs history** — the monthly projection shows "accruing…" until there are ≥3h of data;
  it sharpens as the heartbeat accumulates a representative run-rate.
- **Governance is derived, not a 429 log** — per-user rate-limit attribution isn't in standard
  telemetry, so the governance view infers pressure from token bins vs the 500k TPM limit.
- **One workspace, two schemas** — App Insights is workspace-based and linked to the same workspace as the
  gateway logs, so `customMetrics` (via the component) and `ApiManagementGatewayLlmLog` /
  `ApiManagementGatewayLogs` are queryable together. The token rows also appear as `AppMetrics` /
  `Properties` when you query the workspace directly.

## Scaling considerations (10k+ users)

This PoC is demo-sized. At enterprise scale the dominant cost is LLM inference — the gateway and its logs
are <1% beside it — so the goal isn't to log less, it's to log the right shape and spend effort on the
backend. What changes:

- **Attribution moves from the metric to the log join.** Custom metrics cap at ~50k active time series
  per region/subscription, and an `oid` dimension blows that past a few thousand users. Drop `oid` from
  the metric (keep low-cardinality dims like `model`/`team`) and source per-developer chargeback from the
  `GatewayLlmLog ⋈ copilot-finops` join — logs have no cardinality cap. (The demo keeps `oid` on the metric
  because at ~60 devs the cap isn't close, and the synthetic fleet is metric-only.)
- **Keep the billing path at 100% sampling** — `GatewayLlmLogs` and the trace must both be complete; sample
  only verbose diagnostics, never the chargeback join.
- **Never log prompt/completion bodies** — already the default here (`largeLanguageModel.logs:"enabled"`,
  no `requests`/`responses`). Bodies would multiply ingestion ~30× into TB/month.
- **Right-size the gateway and backend** — Standard v2 (VNet) or Premium APIM; size Foundry with PTUs +
  pay-as-you-go spillover. Prompt caching (tracked in *Context window & caching*) cuts the dominant cost.
  Note `llm-token-limit` counters are per-region, so a multi-region limit is `limit × regions`.
- **Replace the runtime Graph group-check with token claims (Option A)** — app roles or a groups claim
  avoid the per-request Graph dependency and throttling risk. (Option B already uses Foundry RBAC.)
- **Tier retention** — keep `GatewayLlmLog` in Analytics, push verbose `GatewayLogs` to Basic Logs, archive
  old data, and use a commitment tier at steady volume to cut ingestion ~15–30%.

## Teardown

The workbook and heartbeat resources are all in `rg-copilot-foundry-poc`, so `bash ../infra/cleanup.sh`
removes them. To drop just the workbook:
`az resource delete --ids $(az resource list -g rg-copilot-foundry-poc --resource-type microsoft.insights/workbooks --query "[0].id" -o tsv)`.
Synthetic telemetry already in App Insights ages out with the workspace retention.

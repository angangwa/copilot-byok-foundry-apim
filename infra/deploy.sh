#!/usr/bin/env bash
# =============================================================================
#  Governed GitHub Copilot  ->  private-RBAC Foundry model, via Azure APIM
#  Reproducible deploy script (no private networking — Foundry stays public).
# =============================================================================
#
#  WHAT THIS BUILDS (and the one idea to hold in your head):
#  ---------------------------------------------------------------------------
#  A developer's Copilot client sends an Entra ID (Azure AD) access token to
#  APIM. APIM answers three questions before letting the call through:
#     1. "Is this a real token from our tenant?"          (validate-azure-ad-token)
#     2. "Is this user in the allowed security group?"    (call to Microsoft Graph)
#     3. "Are they under their token budget?"             (llm-token-limit)
#  ...then APIM THROWS AWAY the developer's token and calls Foundry using its
#  OWN identity (a "managed identity"). Foundry only trusts APIM's identity, so
#  a developer can't skip the gateway and call Foundry directly.
#
#  TWO IDENTITIES / TWO TOKENS — this is the crux:
#     * Developer token  -> minted on the laptop, audience "cognitiveservices".
#                           APIM uses it only to identify+authorize the user.
#     * APIM's MI token  -> minted by Azure for APIM's managed identity.
#                           This is what actually calls Foundry and Graph.
#
#  KEY TERMS for newcomers:
#     * Entra ID            = Azure's identity provider (formerly "Azure AD").
#     * Managed Identity(MI)= an Entra identity Azure creates+manages for a
#                             resource (here APIM). No passwords/secrets to store.
#                             It shows up in Entra as an "Enterprise application".
#     * Service Principal   = the in-tenant object representing that identity.
#     * Azure RBAC          = "who can do what to Azure resources" (e.g. call
#                             this Foundry account). Lives on the resource's IAM.
#     * Graph app permission= "what an app can read/do in the directory" (e.g.
#                             read group membership). A separate system from RBAC.
#     * APIM "named value"  = a reusable variable referenced from policy as
#                             {{name}} (think: config/secrets for policies).
#     * APIM "policy"       = XML pipeline that runs on every request (our gate).
#
#  PREREQS: `az login` as a subscription **Owner** (needs to assign RBAC roles)
#           who is also an **Entra admin** (needs to grant the Graph permission).
# =============================================================================
set -euo pipefail

# ----- Environment-specific identifiers — load from the git-ignored config.env --------------
#  Copy config.env.example (repo root) to config.env and fill in your own SUBSCRIPTION_ID,
#  TENANT_ID, and GROUP_OID. Resource NAMES below are non-secret defaults you can override.
HERE="$(cd "$(dirname "$0")" && pwd)"
CONFIG="${CONFIG:-$HERE/../config.env}"
# shellcheck disable=SC1090
[ -f "$CONFIG" ] && . "$CONFIG"
: "${SUBSCRIPTION_ID:?Set SUBSCRIPTION_ID — copy config.env.example to config.env (repo root)}"
: "${TENANT_ID:?Set TENANT_ID in config.env}"
: "${GROUP_OID:?Set GROUP_OID (object ID of the copilot-users group) in config.env}"

SUB="$SUBSCRIPTION_ID"                               # Azure subscription ID
TENANT="$TENANT_ID"                                  # Entra tenant ID (validates dev tokens)
LOC="${LOCATION:-eastus2}"                           # region (gpt-4.1 + APIM v2 both available here)
RG="${RG:-rg-copilot-foundry-poc}"                   # resource group to create
SVC="${SVC:-apim-copilot-poc}"                       # APIM instance name (-> https://<SVC>.azure-api.net)
FOUNDRY="${FOUNDRY:-cog-copilot-poc}"                # Foundry / AI Services account name

az account set --subscription "$SUB"                 # make sure every command targets the right subscription


# ============================================================================
# 1. RESOURCE GROUP — a container that holds all the resources below.
#    Deleting this one RG tears down the entire PoC.
# ============================================================================
az group create -n "$RG" -l "$LOC" -o none


# ============================================================================
# 2. FOUNDRY (the model host) + a gpt-4.1 model deployment
#    ------------------------------------------------------------------------
#    * "AIServices" kind = the multi-service Azure AI / Foundry account that
#      exposes the Azure OpenAI data plane at https://<name>.openai.azure.com.
#    * --custom-domain gives it that stable <name> subdomain, which is REQUIRED
#      for Entra-token (keyless) auth to the data plane.
#    * Public network access stays ON (we intentionally skip private networking).
#    * NOTE: this account is created with local/key auth disabled by default,
#      so the ONLY way in is an Entra token — exactly what we want.
# ============================================================================
az cognitiveservices account create -n "$FOUNDRY" -g "$RG" -l "$LOC" \
  --kind AIServices --sku S0 --custom-domain "$FOUNDRY" --yes -o none

#    A "deployment" = a named instance of a model you can call. The deployment
#    NAME ("gpt-4.1") is what the client sends as the "model" field in requests.
#    --sku-capacity 50  => 50,000 tokens-per-minute of throughput for this model.
az cognitiveservices account deployment create -n "$FOUNDRY" -g "$RG" \
  --deployment-name gpt-4.1 --model-name gpt-4.1 --model-version 2025-04-14 \
  --model-format OpenAI --sku-name Standard --sku-capacity 50 -o none

#    You can add MORE models the same way — each gets a deployment NAME the client
#    selects via the request body's "model" field. No APIM change needed (one
#    operation carries any model). Example: the "model router", a single model
#    that auto-picks the best underlying model per prompt. Sized at 900 (=900k TPM)
#    so it comfortably exceeds the per-developer 500k TPM policy limit — the backend
#    deployment capacity stays the real ceiling for hands-on model-router testing.
#    Override ROUTER_CAPACITY if your subscription's model-router quota is constrained.
az cognitiveservices account deployment create -n "$FOUNDRY" -g "$RG" \
  --deployment-name model-router --model-name model-router --model-version 2025-11-18 \
  --model-format OpenAI --sku-name GlobalStandard --sku-capacity "${ROUTER_CAPACITY:-900}" -o none

#    A reasoning model (gpt-5-mini) — needed for the GitHub Copilot CLI's Responses wire-api,
#    which runs stateless and requires reasoning.encrypted_content (non-reasoning models like
#    gpt-4.1, and model-router, can't provide it). Optional, but enables the CLI /responses demo.
az cognitiveservices account deployment create -n "$FOUNDRY" -g "$RG" \
  --deployment-name gpt-5-mini --model-name gpt-5-mini --model-version 2025-08-07 \
  --model-format OpenAI --sku-name GlobalStandard --sku-capacity 50 -o none

#    KEY model-router quirk: it serves its two APIs on TWO different endpoints —
#    /chat/completions on the classic data plane (https://<name>.openai.azure.com,
#    audience cognitiveservices) and /responses ONLY on a Foundry PROJECT endpoint
#    (https://<name>.services.ai.azure.com/api/projects/<proj>, audience ai.azure.com).
#    Named models work on both; only model-router is split. So we create a project and
#    the APIM policy routes /responses -> project, everything else -> data plane.
#    (Reproduced with Microsoft's own SDK; see README.)
PROJECT=copilot-proj
az rest --method PUT \
  --url "https://management.azure.com/subscriptions/$SUB/resourceGroups/$RG/providers/Microsoft.CognitiveServices/accounts/$FOUNDRY/projects/$PROJECT?api-version=2025-06-01" \
  --headers "Content-Type=application/json" \
  --body '{"location":"'"$LOC"'","identity":{"type":"SystemAssigned"},"properties":{"displayName":"Copilot PoC project"}}' -o none


# ============================================================================
# 3. MONITORING STORE — ONE Log Analytics workspace backs everything.
#    ------------------------------------------------------------------------
#    A single workspace holds BOTH signals the FinOps dashboard reads:
#      * App Insights token metrics (per-developer customMetrics), and
#      * the gateway resource logs (served model + the per-developer correlation trace).
#    Creating the workspace first and linking App Insights to it (--workspace) keeps every
#    signal co-located, so the per-developer served-model join is a single-workspace query.
#    (Needs the application-insights CLI extension; install it quietly if absent.)
# ============================================================================
az extension add -n application-insights -y >/dev/null 2>&1 || true
az monitor log-analytics workspace create -g "$RG" -n law-copilot-poc -l "$LOC" -o none
LAW_ID=$(az monitor log-analytics workspace show -g "$RG" -n law-copilot-poc --query id -o tsv)
az monitor app-insights component create --app appi-copilot-poc -l "$LOC" -g "$RG" --kind web \
  --workspace "$LAW_ID" -o none


# ============================================================================
# 4. APIM (the gateway), Basic v2 tier, with a SYSTEM-ASSIGNED MANAGED IDENTITY
#    ------------------------------------------------------------------------
#    Why an ARM template (apim.json) instead of `az apim create`? The CLI in
#    this version doesn't accept the "BasicV2" SKU, so we deploy via a tiny ARM
#    template (apim.json) that sets sku.name=BasicV2 and identity=SystemAssigned.
#
#    Enabling the system-assigned MI here is what makes Azure create an Entra
#    identity (service principal / "enterprise app") tied to this APIM instance.
#    We grab its principalId (object ID) — we'll grant it access in steps 5 & 6.
#    Provisioning takes a few minutes (v2 is much faster than classic APIM).
# ============================================================================
az deployment group create -g "$RG" --name apim-deploy --template-file "$HERE/apim.json" \
  --parameters serviceName="$SVC" location="$LOC" publisherEmail="${PUBLISHER_EMAIL:-publisher@example.com}" -o none
APIM_MI=$(az apim show -n "$SVC" -g "$RG" --query identity.principalId -o tsv)


# ============================================================================
# 5. AZURE RBAC — let APIM's identity actually CALL the Foundry model.
#    ------------------------------------------------------------------------
#    "Cognitive Services OpenAI User" is the data-plane role for running models.
#    We scope it to the Foundry account, assigned to APIM's MI. This is the ONLY
#    identity with a role on Foundry — developers have none, which is precisely
#    what makes the gateway non-bypassable (a dev calling Foundry directly = 401).
# ============================================================================
FOUNDRY_ID=$(az cognitiveservices account show -n "$FOUNDRY" -g "$RG" --query id -o tsv)
az role assignment create --assignee-object-id "$APIM_MI" --assignee-principal-type ServicePrincipal \
  --role "Cognitive Services OpenAI User" --scope "$FOUNDRY_ID" -o none
#    Also grant "Cognitive Services User" — needed for the ai.azure.com PROJECT
#    inference hop used by the /responses route (model-router Responses).
az role assignment create --assignee-object-id "$APIM_MI" --assignee-principal-type ServicePrincipal \
  --role "Cognitive Services User" --scope "$FOUNDRY_ID" -o none


# ============================================================================
# 6. MICROSOFT GRAPH PERMISSION — let APIM's identity READ group membership.
#    ------------------------------------------------------------------------
#    This is a DIFFERENT permission system from Azure RBAC (step 5). Here we
#    grant the APIM MI an *application permission* on Microsoft Graph so the
#    inbound policy can ask Graph "is this developer in copilot-users?".
#
#    "GroupMember.Read.All" is sufficient because our policy LISTS a group's
#    members (filtered by the user's id) — see apim-policy.xml. (The simpler-
#    looking checkMemberGroups call would instead require the broader
#    Directory.Read.All, so we deliberately avoid it.)
#
#    Mechanics: Microsoft Graph is itself a service principal (well-known appId
#    00000003-0000-0000-c000-000000000000). We find the role's ID on it, then
#    create an "appRoleAssignment" FROM the APIM MI TO Graph. Creating this
#    assignment as an admin IS the admin-consent — no extra consent step.
# ============================================================================
GRAPH_SP=$(az ad sp show --id 00000003-0000-0000-c000-000000000000 --query id -o tsv)
ROLE_ID=$(az ad sp show --id 00000003-0000-0000-c000-000000000000 \
  --query "appRoles[?value=='GroupMember.Read.All' && contains(allowedMemberTypes,'Application')].id | [0]" -o tsv)
az rest --method POST --url "https://graph.microsoft.com/v1.0/servicePrincipals/$APIM_MI/appRoleAssignments" \
  --headers "Content-Type=application/json" \
  --body "{\"principalId\":\"$APIM_MI\",\"resourceId\":\"$GRAPH_SP\",\"appRoleId\":\"$ROLE_ID\"}" -o none
# Entra usually makes this effective within a few minutes; allow up to ~15 for the
# permission to show up in the MI's freshly minted Graph tokens.
echo "NOTE: allow a few minutes for the Graph permission to propagate before the group check works."


# ============================================================================
# 7. APIM NAMED VALUES — config the policy references as {{name}}.
#    ------------------------------------------------------------------------
#      tenant-id               -> which tenant's tokens to trust
#      copilot-allowed-group-id-> which security group grants access
#      foundry-endpoint        -> where APIM forwards the (re-authenticated) call
# ============================================================================
#      foundry-endpoint         -> data-plane host (chat/completions + named-model responses)
#      foundry-project-endpoint -> project endpoint (model-router /responses, ai.azure.com aud)
for kv in "tenant-id=$TENANT" "copilot-allowed-group-id=$GROUP_OID" \
          "foundry-endpoint=https://$FOUNDRY.openai.azure.com" \
          "foundry-project-endpoint=https://$FOUNDRY.services.ai.azure.com/api/projects/$PROJECT"; do
  az apim nv create -g "$RG" --service-name "$SVC" --named-value-id "${kv%%=*}" \
    --display-name "${kv%%=*}" --value "${kv#*=}" -o none
done


# ============================================================================
# 8. THE API + ITS OPERATION — what APIM exposes to clients.
#    ------------------------------------------------------------------------
#    * --path foundry  => the API lives under https://<SVC>.azure-api.net/foundry
#    * --subscription-required false  => IMPORTANT. By default APIM demands its
#      own "subscription key" header. Copilot's keyless client never sends one,
#      so we turn it off — the Entra token (checked by our policy) is the gate.
#    * The operation maps POST /openai/v1/chat/completions, the OpenAI-compatible
#      surface the Copilot "azure" client calls (model name goes in the body).
# ============================================================================
az apim api create -g "$RG" --service-name "$SVC" --api-id foundry --path foundry \
  --display-name "Foundry (governed)" --protocols https --subscription-required false \
  --service-url "https://$FOUNDRY.openai.azure.com" -o none
az apim api operation create -g "$RG" --service-name "$SVC" --api-id foundry \
  --operation-id chat-completions --display-name "Chat Completions" \
  --method POST --url-template "/openai/v1/chat/completions" -o none
#    Also expose the OpenAI Responses API surface. The same API-scoped policy
#    (auth/group/limit/MI-swap) applies automatically. Use a concrete model such
#    as gpt-4.1 here — model-router does not support /responses.
az apim api operation create -g "$RG" --service-name "$SVC" --api-id foundry \
  --operation-id responses --display-name "Responses" \
  --method POST --url-template "/openai/v1/responses" -o none


# ============================================================================
# 9. WIRE APIM -> APPLICATION INSIGHTS (so token metrics have somewhere to land)
#    ------------------------------------------------------------------------
#    A "logger" tells APIM how to reach App Insights; a "diagnostic" attaches
#    that logger to our API and enables metrics. We use `az rest` (raw ARM REST)
#    because these objects aren't fully covered by the `az apim` CLI verbs.
# ============================================================================
APPI_ID="/subscriptions/$SUB/resourceGroups/$RG/providers/microsoft.insights/components/appi-copilot-poc"
CONN=$(az monitor app-insights component show --app appi-copilot-poc -g "$RG" --query connectionString -o tsv)
TMP=$(mktemp -d)                                     # scratch dir for the JSON request bodies below
# 9a. the logger (App Insights connection)
python3 -c "import json;json.dump({'properties':{'loggerType':'applicationInsights','credentials':{'connectionString':'$CONN'},'resourceId':'$APPI_ID'}},open('$TMP/logger.json','w'))"
az rest --method PUT --url "https://management.azure.com/subscriptions/$SUB/resourceGroups/$RG/providers/Microsoft.ApiManagement/service/$SVC/loggers/appinsights?api-version=2024-05-01" \
  --headers "Content-Type=application/json" --body @"$TMP/logger.json" -o none
# 9b. the diagnostic (attach logger to the foundry API, enable metrics)
LOGGERID="/subscriptions/$SUB/resourceGroups/$RG/providers/Microsoft.ApiManagement/service/$SVC/loggers/appinsights"
python3 -c "import json;json.dump({'properties':{'loggerId':'$LOGGERID','alwaysLog':'allErrors','sampling':{'samplingType':'fixed','percentage':100},'metrics':True}},open('$TMP/diag.json','w'))"
az rest --method PUT --url "https://management.azure.com/subscriptions/$SUB/resourceGroups/$RG/providers/Microsoft.ApiManagement/service/$SVC/apis/foundry/diagnostics/applicationinsights?api-version=2024-05-01" \
  --headers "Content-Type=application/json" --body @"$TMP/diag.json" -o none

# 9c. ROUTED-MODEL LOGGING (GatewayLlmLogs) — capture which model model-router actually served.
#    ------------------------------------------------------------------------
#    The token METRIC above (llm-emit-token-metric, step 10/(3)) runs INBOUND, so its
#    `model` dimension is always the REQUESTED name. For model-router that is literally
#    "model-router" — it CAN'T see which underlying model actually served the request
#    (that's only in the response, which streams — so it can't be buffered and read here).
#    To record the SERVED model AND tie it back to the developer, route two gateway log
#    categories to the workspace created in step 3:
#      * GatewayLlmLogs -> ApiManagementGatewayLlmLog: DeploymentName (= model-router) next to
#        ModelName (= e.g. gpt-5-nano-...) + token counts, per request, keyed by CorrelationId.
#      * GatewayLogs    -> ApiManagementGatewayLogs: carries TraceRecords, where the inbound
#        'copilot-finops' trace writes the developer oid on the SAME CorrelationId.
#    Joining the two on CorrelationId yields per-developer x served-model (the FinOps "Live
#    routing" widgets; see finops/README.md). The per-developer token dashboard also runs on the
#    App Insights metric above — in the same workspace.
APIM_RES="/subscriptions/$SUB/resourceGroups/$RG/providers/Microsoft.ApiManagement/service/$SVC"
#    --export-to-resource-specific true is REQUIRED. Without it the data lands in the legacy
#    AzureDiagnostics table (as deploymentName_s / modelName_s columns) instead of the
#    ApiManagementGatewayLlmLog table, and the dashboard widget stays empty. First rows
#    appear ~15 min after enabling (a brand-new workspace can take up to ~2h).
az monitor diagnostic-settings create --name apim-llm-logs --resource "$APIM_RES" \
  --workspace "$LAW_ID" --export-to-resource-specific true \
  --logs '[{"category":"GatewayLlmLogs","enabled":true},{"category":"GatewayLogs","enabled":true}]' -o none

# 9d. Enable LLM logging on the foundry API via APIM's built-in azureMonitor logger.
#    largeLanguageModel.logs=enabled => token usage + SERVED model name ONLY. We deliberately
#    omit "requests"/"responses" so prompt/completion BODIES are NOT logged (no PII, low cost).
#    verbosity=information makes the gateway emit the inbound 'copilot-finops' trace (severity
#    information) into ApiManagementGatewayLogs.TraceRecords, which carries the developer oid.
az rest --method PUT --url "https://management.azure.com$APIM_RES/loggers/azuremonitor?api-version=2024-05-01" \
  --headers "Content-Type=application/json" --body '{"properties":{"loggerType":"azureMonitor"}}' -o none
python3 -c "import json;json.dump({'properties':{'loggerId':'$APIM_RES/loggers/azuremonitor','verbosity':'information','largeLanguageModel':{'logs':'enabled'}}},open('$TMP/llmdiag.json','w'))"
az rest --method PUT --url "https://management.azure.com$APIM_RES/apis/foundry/diagnostics/azuremonitor?api-version=2024-05-01" \
  --headers "Content-Type=application/json" --body @"$TMP/llmdiag.json" -o none


# ============================================================================
# 10. THE INBOUND POLICY — the actual gate (see apim-policy.xml, fully commented)
#    ------------------------------------------------------------------------
#    Applied at the API scope. In order, on every request, it:
#      (1) validates the developer's Entra token (tenant + cognitiveservices aud)
#      (2) authorizes via Graph group membership (cached 1h per user)
#      (3) enforces a per-user tokens-per-minute limit + emits usage metrics
#      (4) swaps in APIM's managed-identity token and forwards to Foundry
#    We PUT it as "rawxml" through ARM REST (the cleanest way to push policy XML).
# ============================================================================
python3 -c "import json;xml=open('$HERE/apim-policy.xml').read();json.dump({'properties':{'format':'rawxml','value':xml}},open('$TMP/policy.json','w'))"
az rest --method PUT --url "https://management.azure.com/subscriptions/$SUB/resourceGroups/$RG/providers/Microsoft.ApiManagement/service/$SVC/apis/foundry/policies/policy?api-version=2024-05-01" \
  --headers "Content-Type=application/json" --body @"$TMP/policy.json" -o none

echo "Done. Gateway: https://$SVC.azure-api.net/foundry/openai/v1/chat/completions"
echo "Next: validate with ./test-gateway.sh, or point VS Code Copilot at the URL above (see README)."

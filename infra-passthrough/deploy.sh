#!/usr/bin/env bash
# =============================================================================
#  PoC #2 — Governed GitHub Copilot -> Foundry, via Azure APIM
#  DEVELOPER-IDENTITY PASS-THROUGH + NETWORK-ENFORCED NO-BYPASS
# =============================================================================
#
#  HOW THIS DIFFERS FROM PoC #1 (../infra/deploy.sh):
#  ---------------------------------------------------------------------------
#  PoC #1: APIM validates the dev token, checks the group via Graph, then SWAPS
#          in APIM's managed-identity token to call a PUBLIC Foundry. Only APIM's
#          MI has a role on Foundry, so identity alone makes the gateway
#          non-bypassable.
#
#  PoC #2 (this script): APIM forwards the developer's OWN token unchanged.
#          Authorization is enforced by Azure RBAC granted to the user GROUP on
#          Foundry. No-bypass is enforced by NETWORK: Foundry is PRIVATE
#          (publicNetworkAccess=Disabled) behind a private endpoint that is
#          reachable ONLY from APIM's integrated subnet. APIM keeps only
#          validate + per-user limit + metering.
#
#          => APIM MI gets NO Foundry role. No Microsoft Graph permission.
#          => APIM must be Standard v2 (Basic v2 can't do outbound VNet integration).
#          => model-router /responses is unsupported (data-plane only; see README).
#
#  PREREQS: `az login` as a subscription **Owner** (to assign the group RBAC role
#           and create networking). The copilot-users group + copilotuser test user
#           from PoC #1 are REUSED (we just grant the group a role on the new Foundry).
# =============================================================================
set -euo pipefail

# ----- Identifiers for THIS deployment (parallel to PoC #1, "-pt" suffixes) ----
# Environment-specific identifiers load from the git-ignored config.env (repo root).
# Copy config.env.example -> config.env and fill in SUBSCRIPTION_ID / TENANT_ID / GROUP_OID.
HERE_CFG="$(cd "$(dirname "$0")" && pwd)"
CONFIG="${CONFIG:-$HERE_CFG/../config.env}"
# shellcheck disable=SC1090
[ -f "$CONFIG" ] && . "$CONFIG"
: "${SUBSCRIPTION_ID:?Set SUBSCRIPTION_ID — copy config.env.example to config.env (repo root)}"
: "${TENANT_ID:?Set TENANT_ID in config.env}"
: "${GROUP_OID:?Set GROUP_OID (object ID of the copilot-users group) in config.env}"

SUB="$SUBSCRIPTION_ID"                               # Azure subscription ID
TENANT="$TENANT_ID"                                  # Entra tenant ID
LOC="${LOCATION:-eastus2}"                           # region (gpt-4.1 + APIM v2 + AIServices PE all available)
RG="${RG:-rg-copilot-foundry-poc-pt}"               # NEW resource group (coexists with Option A)
SVC="${SVC:-apim-copilot-poc-pt}"                   # APIM instance (-> https://<SVC>.azure-api.net)
FOUNDRY="${FOUNDRY:-cog-copilot-poc-pt}"            # Foundry / AI Services account name
# --- networking ---
VNET=vnet-copilot-pt
SNET_APIM=snet-apim                                 # delegated to Microsoft.Web/serverFarms (APIM v2 integration)
SNET_PE=snet-pe                                     # holds the Foundry private endpoint
VNET_CIDR=10.0.0.0/16
APIM_CIDR=10.0.0.0/27                               # /27 = APIM v2 integration minimum
PE_CIDR=10.0.1.0/27
NSG_APIM=nsg-apim
NSG_PE=nsg-pe
PE_NAME=pe-foundry
HERE="$(cd "$(dirname "$0")" && pwd)"

az account set --subscription "$SUB"

# ============================================================================
# 1. RESOURCE GROUP
# ============================================================================
az group create -n "$RG" -l "$LOC" -o none


# ============================================================================
# 2. NETWORKING — VNet + two subnets + NSGs (built BEFORE APIM and the PE)
#    ------------------------------------------------------------------------
#    * snet-apim : delegated to Microsoft.Web/serverFarms; APIM Standard v2
#      integrates OUTBOUND here so it can reach the private Foundry.
#    * snet-pe   : hosts the Foundry private endpoint. We ENABLE private-endpoint
#      network policies on it so the NSG actually applies to PE traffic, then lock
#      the NSG so ONLY snet-apim can reach the PE (even other VNet hosts can't).
# ============================================================================
az network vnet create -g "$RG" -n "$VNET" -l "$LOC" --address-prefixes "$VNET_CIDR" -o none

# NSGs first (so subnets can reference them at create time)
az network nsg create -g "$RG" -n "$NSG_APIM" -l "$LOC" -o none
az network nsg create -g "$RG" -n "$NSG_PE"   -l "$LOC" -o none

# nsg-pe: allow ONLY snet-apim -> PE :443, then deny the rest of the VNet.
az network nsg rule create -g "$RG" --nsg-name "$NSG_PE" -n allow-apim-to-pe \
  --priority 100 --direction Inbound --access Allow --protocol Tcp \
  --source-address-prefixes "$APIM_CIDR" --destination-port-ranges 443 \
  --destination-address-prefixes '*' --source-port-ranges '*' -o none
az network nsg rule create -g "$RG" --nsg-name "$NSG_PE" -n deny-vnet-to-pe \
  --priority 200 --direction Inbound --access Deny --protocol '*' \
  --source-address-prefixes VirtualNetwork --destination-port-ranges '*' \
  --destination-address-prefixes '*' --source-port-ranges '*' -o none

# APIM integration subnet: delegated to Microsoft.Web/serverFarms, NSG attached.
az network vnet subnet create -g "$RG" --vnet-name "$VNET" -n "$SNET_APIM" \
  --address-prefixes "$APIM_CIDR" --delegations Microsoft.Web/serverFarms \
  --network-security-group "$NSG_APIM" -o none

# PE subnet: NSG attached, and private-endpoint network policies ENABLED so the NSG bites.
az network vnet subnet create -g "$RG" --vnet-name "$VNET" -n "$SNET_PE" \
  --address-prefixes "$PE_CIDR" --network-security-group "$NSG_PE" \
  --private-endpoint-network-policies Enabled -o none


# ============================================================================
# 3. FOUNDRY (the model host) + 3 model deployments  — created PUBLIC first,
#    then locked down in step 4. Model deployment is a CONTROL-plane op, so it
#    works from this admin machine regardless of data-plane network access.
# ============================================================================
az cognitiveservices account create -n "$FOUNDRY" -g "$RG" -l "$LOC" \
  --kind AIServices --sku S0 --custom-domain "$FOUNDRY" --yes -o none

az cognitiveservices account deployment create -n "$FOUNDRY" -g "$RG" \
  --deployment-name gpt-4.1 --model-name gpt-4.1 --model-version 2025-04-14 \
  --model-format OpenAI --sku-name Standard --sku-capacity 50 -o none
#    model-router sized at 900 (=900k TPM) so it exceeds the per-developer 500k TPM policy limit.
#    Override ROUTER_CAPACITY if your subscription's model-router quota is constrained.
az cognitiveservices account deployment create -n "$FOUNDRY" -g "$RG" \
  --deployment-name model-router --model-name model-router --model-version 2025-11-18 \
  --model-format OpenAI --sku-name GlobalStandard --sku-capacity "${ROUTER_CAPACITY:-900}" -o none
az cognitiveservices account deployment create -n "$FOUNDRY" -g "$RG" \
  --deployment-name gpt-5-mini --model-name gpt-5-mini --model-version 2025-08-07 \
  --model-format OpenAI --sku-name GlobalStandard --sku-capacity 50 -o none
#  NOTE: no Foundry PROJECT here. PoC #1 needed one for the ai.azure.com /responses
#  hop; pass-through is data-plane only (the dev token's cognitiveservices audience
#  can't reach the project endpoint), so model-router /responses is unsupported.

FOUNDRY_ID=$(az cognitiveservices account show -n "$FOUNDRY" -g "$RG" --query id -o tsv)


# ============================================================================
# 4. PRIVATE ENDPOINT + PRIVATE DNS, then DISABLE public network access.
#    ------------------------------------------------------------------------
#    The PE (groupId "account") gives Foundry a private IP in snet-pe. Three
#    privatelink zones cover the AIServices data planes; we link them to the VNet
#    and attach a dns-zone-group so A records auto-register. After the PE exists,
#    we set publicNetworkAccess=Disabled (+ Deny, bypass AzureServices for control
#    plane / trusted services). From then on, the ONLY way to the model is APIM.
# ============================================================================
az network private-endpoint create -g "$RG" -n "$PE_NAME" -l "$LOC" \
  --vnet-name "$VNET" --subnet "$SNET_PE" \
  --private-connection-resource-id "$FOUNDRY_ID" --group-id account \
  --connection-name "${PE_NAME}-conn" -o none

for zone in privatelink.openai.azure.com privatelink.cognitiveservices.azure.com privatelink.services.ai.azure.com; do
  az network private-dns zone create -g "$RG" -n "$zone" -o none
  az network private-dns link vnet create -g "$RG" -z "$zone" \
    -n "link-$zone" --virtual-network "$VNET" --registration-enabled false -o none
done

# Auto-register the PE's A records into all three zones.
az network private-endpoint dns-zone-group create -g "$RG" \
  --endpoint-name "$PE_NAME" -n default \
  --private-dns-zone privatelink.openai.azure.com --zone-name openai -o none
az network private-endpoint dns-zone-group add -g "$RG" \
  --endpoint-name "$PE_NAME" -n default \
  --private-dns-zone privatelink.cognitiveservices.azure.com --zone-name cognitiveservices -o none
az network private-endpoint dns-zone-group add -g "$RG" \
  --endpoint-name "$PE_NAME" -n default \
  --private-dns-zone privatelink.services.ai.azure.com --zone-name aiservices -o none

# Lock the data plane: disable public network access. With this set, the model is only
# reachable via the private endpoint (APIM's subnet) — control-plane/ARM ops are unaffected.
# Done via a generic ARM update because `az cognitiveservices account update` doesn't expose
# --public-network-access in all CLI versions. (publicNetworkAccess=Disabled is the enforcing
# control; an explicit networkAcls block isn't needed once public access is off.)
az resource update --ids "$FOUNDRY_ID" \
  --set properties.publicNetworkAccess=Disabled -o none


# ============================================================================
# 5. MONITORING STORE — ONE Log Analytics workspace backs everything.
#    A single workspace holds both the App Insights token metrics (per-developer customMetrics)
#    and the gateway resource logs (served model + the per-developer correlation trace), so the
#    per-developer served-model join is a single-workspace query. App Insights is linked to it
#    via --workspace. (See infra/deploy.sh for the full rationale.)
# ============================================================================
az extension add -n application-insights -y >/dev/null 2>&1 || true
az monitor log-analytics workspace create -g "$RG" -n law-copilot-poc-pt -l "$LOC" -o none
LAW_ID=$(az monitor log-analytics workspace show -g "$RG" -n law-copilot-poc-pt --query id -o tsv)
az monitor app-insights component create --app appi-copilot-poc-pt -l "$LOC" -g "$RG" --kind web \
  --workspace "$LAW_ID" -o none


# ============================================================================
# 6. APIM (Standard v2 + system MI) via ARM template, THEN enable outbound
#    VNet integration to snet-apim.
#    ------------------------------------------------------------------------
#    Standard v2 is required for outbound VNet integration (Basic v2 can't).
#    We create the instance first (apim.json), then attach it to the delegated
#    subnet via `az apim update` — the doc-verified path for integrate-vnet-outbound.
#    The MI is created but, unlike PoC #1, is granted NO Foundry role.
# ============================================================================
az deployment group create -g "$RG" --name apim-deploy --template-file "$HERE/apim.json" \
  --parameters serviceName="$SVC" location="$LOC" publisherEmail="${PUBLISHER_EMAIL:-publisher@example.com}" -o none
APIM_MI=$(az apim show -n "$SVC" -g "$RG" --query identity.principalId -o tsv)

SNET_APIM_ID=$(az network vnet subnet show -g "$RG" --vnet-name "$VNET" -n "$SNET_APIM" --query id -o tsv)
APIM_ID=$(az apim show -n "$SVC" -g "$RG" --query id -o tsv)
# Standard v2 OUTBOUND integration via REST PATCH. The gateway stays PUBLIC (integration, not
# injection); the API requires virtualNetworkType="External" whenever virtualNetworkConfiguration
# is set. ("External" here = in the VNet but internet-accessible — i.e. public-in / private-out.)
az rest --method PATCH --url "https://management.azure.com${APIM_ID}?api-version=2024-05-01" \
  --headers "Content-Type=application/json" \
  --body "{\"properties\":{\"virtualNetworkType\":\"External\",\"virtualNetworkConfiguration\":{\"subnetResourceId\":\"$SNET_APIM_ID\"}}}" -o none
echo "NOTE: APIM VNet integration patched; wait for provisioningState=Succeeded before further apim ops."
until [ "$(az apim show -n "$SVC" -g "$RG" --query provisioningState -o tsv)" = "Succeeded" ]; do sleep 20; done


# ============================================================================
# 7. AZURE RBAC — grant the GROUP data-plane access on Foundry.
#    ------------------------------------------------------------------------
#    THIS is the authorization mechanism in pass-through: any member of
#    copilot-users, presenting their own token (forwarded by APIM), is allowed
#    to run inference. Non-members get 403 from Foundry natively. No Graph,
#    no APIM group-check, no MI role.
# ============================================================================
az role assignment create --assignee-object-id "$GROUP_OID" --assignee-principal-type Group \
  --role "Cognitive Services OpenAI User" --scope "$FOUNDRY_ID" -o none
echo "NOTE: data-plane RBAC propagation can take ~5-30 min before 200s succeed."


# ============================================================================
# 8. APIM NAMED VALUES — only two now (no group id, no project endpoint).
#      tenant-id        -> which tenant's tokens to validate
#      foundry-endpoint -> the PRIVATE data-plane host APIM forwards to
# ============================================================================
for kv in "tenant-id=$TENANT" \
          "foundry-endpoint=https://$FOUNDRY.openai.azure.com"; do
  az apim nv create -g "$RG" --service-name "$SVC" --named-value-id "${kv%%=*}" \
    --display-name "${kv%%=*}" --value "${kv#*=}" -o none
done


# ============================================================================
# 9. THE API + ITS OPERATIONS — identical surface to PoC #1.
#    --subscription-required false  => Entra token is the gate, not an APIM key.
# ============================================================================
az apim api create -g "$RG" --service-name "$SVC" --api-id foundry --path foundry \
  --display-name "Foundry (governed, pass-through)" --protocols https --subscription-required false \
  --service-url "https://$FOUNDRY.openai.azure.com" -o none
az apim api operation create -g "$RG" --service-name "$SVC" --api-id foundry \
  --operation-id chat-completions --display-name "Chat Completions" \
  --method POST --url-template "/openai/v1/chat/completions" -o none
#  /responses works for NAMED models (gpt-4.1, gpt-5-mini) on the data plane;
#  model-router /responses is unsupported in pass-through (see README).
az apim api operation create -g "$RG" --service-name "$SVC" --api-id foundry \
  --operation-id responses --display-name "Responses" \
  --method POST --url-template "/openai/v1/responses" -o none


# ============================================================================
# 10. WIRE APIM -> APPLICATION INSIGHTS (per-user token metrics land here)
# ============================================================================
APPI_ID="/subscriptions/$SUB/resourceGroups/$RG/providers/microsoft.insights/components/appi-copilot-poc-pt"
CONN=$(az monitor app-insights component show --app appi-copilot-poc-pt -g "$RG" --query connectionString -o tsv)
TMP=$(mktemp -d)
python3 -c "import json;json.dump({'properties':{'loggerType':'applicationInsights','credentials':{'connectionString':'$CONN'},'resourceId':'$APPI_ID'}},open('$TMP/logger.json','w'))"
az rest --method PUT --url "https://management.azure.com/subscriptions/$SUB/resourceGroups/$RG/providers/Microsoft.ApiManagement/service/$SVC/loggers/appinsights?api-version=2024-05-01" \
  --headers "Content-Type=application/json" --body @"$TMP/logger.json" -o none
LOGGERID="/subscriptions/$SUB/resourceGroups/$RG/providers/Microsoft.ApiManagement/service/$SVC/loggers/appinsights"
python3 -c "import json;json.dump({'properties':{'loggerId':'$LOGGERID','alwaysLog':'allErrors','sampling':{'samplingType':'fixed','percentage':100},'metrics':True}},open('$TMP/diag.json','w'))"
az rest --method PUT --url "https://management.azure.com/subscriptions/$SUB/resourceGroups/$RG/providers/Microsoft.ApiManagement/service/$SVC/apis/foundry/diagnostics/applicationinsights?api-version=2024-05-01" \
  --headers "Content-Type=application/json" --body @"$TMP/diag.json" -o none

# 10b/c. ROUTED-MODEL LOGGING + PER-DEVELOPER ATTRIBUTION — see infra/deploy.sh for the full rationale.
#    The inbound token metric only records the REQUESTED name (e.g. "model-router"); the SERVED model
#    is captured by the gateway's generative-AI logs. Two categories route to the workspace from step 5:
#      * GatewayLlmLogs -> ApiManagementGatewayLlmLog: DeploymentName + ModelName + tokens, per request.
#      * GatewayLogs    -> ApiManagementGatewayLogs:   TraceRecords carrying the inbound 'copilot-finops'
#        trace (developer oid) on the SAME CorrelationId.
#    Joining the two on CorrelationId yields per-developer x served-model. Token+model only, NO bodies => no PII.
APIM_RES="/subscriptions/$SUB/resourceGroups/$RG/providers/Microsoft.ApiManagement/service/$SVC"
# --export-to-resource-specific true is REQUIRED (else data goes to legacy AzureDiagnostics, not the
# resource-specific table, and the dashboard widget stays empty). First rows appear ~15 min later.
az monitor diagnostic-settings create --name apim-llm-logs --resource "$APIM_RES" \
  --workspace "$LAW_ID" --export-to-resource-specific true \
  --logs '[{"category":"GatewayLlmLogs","enabled":true},{"category":"GatewayLogs","enabled":true}]' -o none
az rest --method PUT --url "https://management.azure.com$APIM_RES/loggers/azuremonitor?api-version=2024-05-01" \
  --headers "Content-Type=application/json" --body '{"properties":{"loggerType":"azureMonitor"}}' -o none
# verbosity=information makes the gateway emit the inbound 'copilot-finops' trace into GatewayLogs.
python3 -c "import json;json.dump({'properties':{'loggerId':'$APIM_RES/loggers/azuremonitor','verbosity':'information','largeLanguageModel':{'logs':'enabled'}}},open('$TMP/llmdiag.json','w'))"
az rest --method PUT --url "https://management.azure.com$APIM_RES/apis/foundry/diagnostics/azuremonitor?api-version=2024-05-01" \
  --headers "Content-Type=application/json" --body @"$TMP/llmdiag.json" -o none


# ============================================================================
# 11. THE INBOUND POLICY — the pass-through gate (apim-policy-passthrough.xml):
#       (1) validate the dev's Entra token (tenant + cognitiveservices aud)
#       (2) per-user TPM limit + usage metrics keyed on Entra oid
#       (3) set backend = private data-plane endpoint; forward the token UNCHANGED
# ============================================================================
python3 -c "import json;xml=open('$HERE/apim-policy-passthrough.xml').read();json.dump({'properties':{'format':'rawxml','value':xml}},open('$TMP/policy.json','w'))"
az rest --method PUT --url "https://management.azure.com/subscriptions/$SUB/resourceGroups/$RG/providers/Microsoft.ApiManagement/service/$SVC/apis/foundry/policies/policy?api-version=2024-05-01" \
  --headers "Content-Type=application/json" --body @"$TMP/policy.json" -o none

echo "Done. Gateway: https://$SVC.azure-api.net/foundry/openai/v1/chat/completions"
echo "Next: wait ~5-30 min for RBAC propagation, then ./test-gateway.sh"

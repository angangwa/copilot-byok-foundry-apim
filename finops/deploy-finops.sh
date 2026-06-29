#!/usr/bin/env bash
# Publish the Copilot per-developer FinOps workbook into the resource group,
# bound to the App Insights resource that holds the APIM token metrics.
# Idempotent: re-running updates the same workbook in place.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# config.env (real IDs / overrides) is git-ignored; load it if present.
if [ -f "$DIR/../config.env" ]; then set -a; . "$DIR/../config.env"; set +a; fi
RG="${RG:-rg-copilot-foundry-poc}"
APPI="${APPINSIGHTS_APP:-appi-copilot-poc}"
DISPLAY="${WORKBOOK_NAME:-Copilot FinOps — per-developer usage & cost}"

echo "Resolving App Insights '$APPI' in '$RG'…"
APPI_ID="$(az monitor app-insights component show --app "$APPI" -g "$RG" --query id -o tsv)"
[ -n "$APPI_ID" ] || { echo "Could not resolve App Insights resource id." >&2; exit 1; }

# Resolve the Log Analytics workspace that the 'Live routing' widget queries (GatewayLlmLogs).
# Most robust: read the target straight from the APIM diagnostic setting (so the widget always points
# wherever the routed-model logs actually land). Then fall back to the named workspace infra/deploy.sh
# creates, then App Insights' own workspace, then the only workspace in the RG.
SVC="${SVC:-apim-copilot-poc}"
APIM_RES_ID="$(az apim show -n "$SVC" -g "$RG" --query id -o tsv 2>/dev/null || true)"
LAW_ID=""
[ -n "$APIM_RES_ID" ] && LAW_ID="$(az monitor diagnostic-settings list --resource "$APIM_RES_ID" \
  --query "[?logs[?category=='GatewayLlmLogs' && enabled]].workspaceId | [0]" -o tsv 2>/dev/null || true)"
[ -n "$LAW_ID" ] || LAW_ID="$(az monitor log-analytics workspace show -g "$RG" -n law-copilot-poc --query id -o tsv 2>/dev/null || true)"
[ -n "$LAW_ID" ] || LAW_ID="$(az monitor app-insights component show --app "$APPI" -g "$RG" --query "properties.WorkspaceResourceId" -o tsv 2>/dev/null || true)"
[ -n "$LAW_ID" ] || LAW_ID="$(az monitor log-analytics workspace list -g "$RG" --query "[0].id" -o tsv 2>/dev/null || true)"
[ -n "$LAW_ID" ] && echo "Log Analytics workspace (routed-model logs): $LAW_ID" || echo "WARN: no GatewayLlmLogs workspace found — 'Live routing' widget stays empty until logging is enabled (see README)."

# Inject the real resource ids into the workbook, then write an ARM parameters file
# (avoids CLI arg-length / quoting limits for the large serialized payload).
PARAMS="$(mktemp)"; trap 'rm -f "$PARAMS"' EXIT
python3 - "$DIR/workbook.json" "$APPI_ID" "$DISPLAY" "$LAW_ID" > "$PARAMS" <<'PY'
import json, sys
wb_path, appi_id, display = sys.argv[1], sys.argv[2], sys.argv[3]
law_id = sys.argv[4] if len(sys.argv) > 4 else ""
serialized = open(wb_path).read().replace("{APPI_RESOURCE_ID}", appi_id).replace("{LAW_RESOURCE_ID}", law_id)
# validate it parses after substitution
json.loads(serialized)
json.dump({
  "$schema": "https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#",
  "contentVersion": "1.0.0.0",
  "parameters": {
    "workbookDisplayName": {"value": display},
    "workbookSourceId": {"value": appi_id},
    "serializedData": {"value": serialized}
  }
}, sys.stdout)
PY

echo "Deploying workbook '$DISPLAY'…"
WB_ID="$(az deployment group create -g "$RG" --name finops-workbook \
  --template-file "$DIR/workbook.template.json" \
  --parameters "@$PARAMS" \
  --query "properties.outputs.workbookResourceId.value" -o tsv)"

echo "Done. Workbook resource: $WB_ID"
echo "Open: Azure portal → Monitor → Workbooks → '$DISPLAY' (or the App Insights resource → Workbooks)."

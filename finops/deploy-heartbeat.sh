#!/usr/bin/env bash
# Stand up a scheduled "heartbeat" that keeps emitting synthetic usage so the
# workbook's multi-day trend fills out over time (backdating is capped at ~1h, so
# a real trend can only be grown by emitting "now" on a schedule).
#
# Builds the seeder image in the cloud (az acr build — no local Docker) and runs
# it as an Azure Container Apps Job on a cron schedule. All resources land in the
# same resource group, so `infra/cleanup.sh` tears them down with everything else.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "$DIR/../config.env" ]; then set -a; . "$DIR/../config.env"; set +a; fi

RG="${RG:-rg-copilot-foundry-poc}"
LOC="${LOCATION:-eastus2}"
APPI="${APPINSIGHTS_APP:-appi-copilot-poc}"
ACR="${FINOPS_ACR:-acrcopilotfinops$RANDOM}"      # globally-unique; override in config.env to reuse
ENVN="${FINOPS_CAE:-cae-copilot-finops}"
JOB="${FINOPS_JOB:-finops-seeder}"
CRON="${FINOPS_CRON:-*/30 * * * *}"               # every 30 min
IMG="copilot-finops-seeder:latest"

echo "[1/5] Extensions / providers…"
az extension add -n containerapp --upgrade -y >/dev/null 2>&1 || true
az provider register -n Microsoft.App --wait >/dev/null 2>&1 || true
az provider register -n Microsoft.OperationalInsights --wait >/dev/null 2>&1 || true

echo "[2/5] ACR '$ACR' + cloud image build…"
az acr show -n "$ACR" -g "$RG" >/dev/null 2>&1 || \
  az acr create -n "$ACR" -g "$RG" --sku Basic --admin-enabled true -o none
az acr build -r "$ACR" -t "$IMG" "$DIR" -o none
ACR_SERVER="$(az acr show -n "$ACR" -g "$RG" --query loginServer -o tsv)"
ACR_USER="$(az acr credential show -n "$ACR" --query username -o tsv)"
ACR_PASS="$(az acr credential show -n "$ACR" --query 'passwords[0].value' -o tsv)"

echo "[3/5] App Insights connection string…"
CONN="$(az monitor app-insights component show --app "$APPI" -g "$RG" --query connectionString -o tsv)"
[ -n "$CONN" ] || { echo "Could not read App Insights connection string." >&2; exit 1; }

echo "[4/5] Container Apps environment '$ENVN'…"
az containerapp env show -n "$ENVN" -g "$RG" >/dev/null 2>&1 || \
  az containerapp env create -n "$ENVN" -g "$RG" -l "$LOC" -o none

echo "[5/5] Scheduled job '$JOB' (cron: $CRON)…"
az containerapp job create -n "$JOB" -g "$RG" --environment "$ENVN" \
  --trigger-type Schedule --cron-expression "$CRON" \
  --replica-timeout 600 --replica-retry-limit 1 --parallelism 1 --replica-completion-count 1 \
  --image "$ACR_SERVER/$IMG" \
  --registry-server "$ACR_SERVER" --registry-username "$ACR_USER" --registry-password "$ACR_PASS" \
  --cpu 0.25 --memory 0.5Gi \
  --env-vars "APPLICATIONINSIGHTS_CONNECTION_STRING=$CONN" "N_DEVS=${N_DEVS:-60}" \
             "WINDOW_MIN=${HEARTBEAT_WINDOW_MIN:-30}" "BUCKET_MIN=5" "REQ_RATE=${REQ_RATE:-12}" \
  -o none 2>/dev/null || \
az containerapp job update -n "$JOB" -g "$RG" \
  --image "$ACR_SERVER/$IMG" \
  --set-env-vars "APPLICATIONINSIGHTS_CONNECTION_STRING=$CONN" "WINDOW_MIN=${HEARTBEAT_WINDOW_MIN:-30}" "BUCKET_MIN=5" "REQ_RATE=${REQ_RATE:-12}" \
  -o none

echo
echo "Done. Job '$JOB' runs every: $CRON  (ACR: $ACR)"
echo "Kick off one run now:   az containerapp job start -n $JOB -g $RG"
echo "Watch executions:       az containerapp job execution list -n $JOB -g $RG -o table"
echo "Stop it (keep data):    az containerapp job update -n $JOB -g $RG --trigger-type Manual"
echo "Tip: add FINOPS_ACR=$ACR to config.env so re-runs reuse this registry."

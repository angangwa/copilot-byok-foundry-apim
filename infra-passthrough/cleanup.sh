#!/usr/bin/env bash
# =============================================================================
#  Tear down Option B (developer-token pass-through).
#  ---------------------------------------------------------------------------
#  Deletes the whole resource group (APIM Standard v2, the private Foundry +
#  deployments, private endpoint, VNet/subnets/NSGs, private DNS zones, App
#  Insights), then PURGES the soft-deleted Cognitive Services account and APIM
#  so their names free up immediately (otherwise they linger ~48 h reserved).
#
#  Does NOT touch the shared `copilot-users` group or `copilotuser` test user
#  (those are reused by Option A). The group's RBAC role assignment was scoped
#  to the Foundry account, so it disappears when the account is deleted.
#
#  Usage:
#     bash cleanup.sh           # interactive — asks you to type the RG name
#     bash cleanup.sh -y        # skip the prompt (or set FORCE=1)
# =============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
CONFIG="${CONFIG:-$HERE/../config.env}"
# shellcheck disable=SC1090
[ -f "$CONFIG" ] && . "$CONFIG"
: "${SUBSCRIPTION_ID:?Set SUBSCRIPTION_ID in config.env (repo root)}"

SUB="$SUBSCRIPTION_ID"
LOC="${LOCATION:-eastus2}"
RG="${RG:-rg-copilot-foundry-poc-pt}"        # Option B resource group
SVC="${SVC:-apim-copilot-poc-pt}"            # APIM instance (for soft-delete purge)
FOUNDRY="${FOUNDRY:-cog-copilot-poc-pt}"     # Cognitive Services account (for purge)

az account set --subscription "$SUB"

if ! az group show -n "$RG" -o none 2>/dev/null; then
  echo "Resource group '$RG' not found — nothing to do."; exit 0
fi

echo "This will PERMANENTLY DELETE resource group '$RG' and everything in it, then purge"
echo "the soft-deleted Cognitive Services account '$FOUNDRY' and APIM '$SVC'. Irreversible."
if [ "${1:-}" != "-y" ] && [ "${FORCE:-}" != "1" ]; then
  read -r -p "Type the resource group name to confirm: " ans
  [ "$ans" = "$RG" ] || { echo "Aborted."; exit 1; }
fi

echo "[1/3] Deleting resource group $RG (several minutes)…"
az group delete -n "$RG" --yes

echo "[2/3] Purging soft-deleted Cognitive Services account $FOUNDRY (frees the name)…"
az cognitiveservices account purge -g "$RG" -n "$FOUNDRY" -l "$LOC" -o none 2>/dev/null \
  && echo "  purged." || echo "  (nothing to purge / soft-delete not active)"

echo "[3/3] Purging soft-deleted APIM $SVC (if the tier soft-deletes)…"
az apim deletedservice purge --service-name "$SVC" --location "$LOC" -o none 2>/dev/null \
  && echo "  purged." || echo "  (nothing to purge / not applicable)"

echo "Done. Option B torn down. (Option A in rg-copilot-foundry-poc is untouched.)"

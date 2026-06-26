#!/usr/bin/env bash
# End-to-end validation of the PASS-THROUGH governed Copilot -> Foundry gateway (PoC #2).
#
# What's DIFFERENT from PoC #1's test (../infra/test-gateway.sh):
#   * Bypass (dev token straight to Foundry) now fails by NETWORK (403, public network
#     access disabled) instead of by identity (401). The dev DOES have RBAC now; the
#     only thing stopping a direct call is that Foundry is private.
#   * Out-of-group (admin) is rejected with 403 by FOUNDRY's RBAC (forwarded by APIM),
#     not by an APIM Graph group-check.
#   * /responses works for NAMED models (gpt-4.1, gpt-5-mini). model-router /responses
#     is intentionally unsupported (data-plane only) — shown as expected-not-200.
#
# Auth: needs a copilotuser "cognitiveservices" token (device-code; ROPC is MFA-blocked).
#   Skip the prompt with:  COPILOT_USER_TOKEN=<jwt> ./test-gateway.sh
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"; [ -f "$HERE/../config.env" ] && . "$HERE/../config.env"
TENANT="${TENANT_ID:?Set TENANT_ID in config.env (repo root)}"
AZ_CLI=04b07795-8ddb-461a-bbee-02f9e1bf7b46            # Azure CLI public client (device-code) — not a secret
SVC="${SVC:-apim-copilot-poc-pt}"; FOUNDRY_NAME="${FOUNDRY:-cog-copilot-poc-pt}"
APIM="https://$SVC.azure-api.net/foundry/openai/v1"
FOUNDRY="https://$FOUNDRY_NAME.openai.azure.com/openai/v1"        # for the bypass test (now network-blocked)

# --- get a copilotuser cognitiveservices token ---
USER_TOK="${COPILOT_USER_TOKEN:-}"
if [ -z "$USER_TOK" ]; then
  DC=$(curl -s -X POST "https://login.microsoftonline.com/$TENANT/oauth2/v2.0/devicecode" \
        --data-urlencode "client_id=$AZ_CLI" --data-urlencode "scope=https://cognitiveservices.azure.com/.default")
  echo "$DC" | python3 -c "import sys,json;d=json.load(sys.stdin);print('Sign in:',d['verification_uri'],' code:',d['user_code'])"
  DEVCODE=$(echo "$DC" | python3 -c "import sys,json;print(json.load(sys.stdin)['device_code'])")
  for _ in $(seq 1 150); do
    R=$(curl -s -X POST "https://login.microsoftonline.com/$TENANT/oauth2/v2.0/token" \
          --data-urlencode "client_id=$AZ_CLI" --data-urlencode "grant_type=urn:ietf:params:oauth:grant-type:device_code" \
          --data-urlencode "device_code=$DEVCODE")
    E=$(echo "$R" | python3 -c "import sys,json;print(json.load(sys.stdin).get('error',''))" 2>/dev/null)
    [ -z "$E" ] && { USER_TOK=$(echo "$R" | python3 -c "import sys,json;print(json.load(sys.stdin)['access_token'])"); break; }
    [ "$E" = "authorization_pending" ] || [ "$E" = "slow_down" ] && { sleep 5; continue; }
    echo "sign-in error: $E"; exit 1
  done
fi
[ -z "$USER_TOK" ] && { echo "no copilotuser token"; exit 1; }
ADMIN_TOK=$(az account get-access-token --resource https://cognitiveservices.azure.com --query accessToken -o tsv)

code(){ curl -s -o /dev/null -w "%{http_code}" -X POST "$1" -H "Authorization: Bearer $2" -H "Content-Type: application/json" -d "$3"; }
model(){ curl -s -X POST "$1" -H "Authorization: Bearer $2" -H "Content-Type: application/json" -d "$3" \
          | python3 -c "import sys,json
try: print(json.load(sys.stdin).get('model','?'))
except: print('-')" 2>/dev/null; }

CHAT='{"model":"%s","messages":[{"role":"user","content":"In 2 words, say hi"}],"max_tokens":20}'
RESP='{"model":"%s","input":"Explain RAG in one sentence."}'

echo
echo "=== Governance (pass-through) ==="
printf "  no token         -> APIM      [exp 401]              HTTP %s\n" "$(curl -s -o /dev/null -w '%{http_code}' -X POST "$APIM/chat/completions" -H 'Content-Type: application/json' -d "$(printf "$CHAT" gpt-4.1)")"
# NOTE: authorization in pass-through is the UNION of Azure RBAC, incl. INHERITED roles. A true
# out-of-group user with NO Foundry data-plane role gets 401 (PermissionDenied) from Foundry. But if
# the account holds a broad/inherited role (e.g. admin has a subscription-level "Foundry User"), it
# returns 200 even though it's not in copilot-users. See README — audit inherited grants for least-priv.
printf "  admin (not group)-> APIM      [200 if inherited role, else 401 no-role] HTTP %s\n" "$(code "$APIM/chat/completions" "$ADMIN_TOK" "$(printf "$CHAT" gpt-4.1)")"
printf "  copilotuser      -> Foundry   [exp 403 net-blocked]  HTTP %s  (bypass: public access disabled)\n" "$(code "$FOUNDRY/chat/completions" "$USER_TOK" "$(printf "$CHAT" gpt-4.1)")"

echo "=== Chat completions (copilotuser) ==="
for m in gpt-4.1 model-router; do
  printf "  chat      · %-13s [exp 200]  HTTP %s  routed=%s\n" "$m" \
    "$(code "$APIM/chat/completions" "$USER_TOK" "$(printf "$CHAT" "$m")")" \
    "$(model "$APIM/chat/completions" "$USER_TOK" "$(printf "$CHAT" "$m")")"
done

echo "=== Responses (copilotuser) — named models work; model-router unsupported ==="
for m in gpt-4.1 gpt-5-mini; do
  printf "  responses · %-13s [exp 200]  HTTP %s  routed=%s\n" "$m" \
    "$(code "$APIM/responses" "$USER_TOK" "$(printf "$RESP" "$m")")" \
    "$(model "$APIM/responses" "$USER_TOK" "$(printf "$RESP" "$m")")"
done
printf "  responses · %-13s [exp NOT 200: data-plane only]  HTTP %s\n" "model-router" \
  "$(code "$APIM/responses" "$USER_TOK" "$(printf "$RESP" model-router)")"

echo
echo "Note: if the 200s return 403, RBAC may still be propagating (~5-30 min). Re-run."

#!/usr/bin/env bash
# Drive the GitHub Copilot CLI through the PASS-THROUGH governed gateway (PoC #2).
# Identical client experience to PoC #1 — only the gateway host changes
# (apim-copilot-poc-pt). The governance model behind it differs (the developer's
# own token is forwarded to a PRIVATE Foundry; RBAC on the group authorizes; the
# network enforces no-bypass) but the client doesn't see any of that.
#
# Auth = the DEVELOPER's Entra token (a member of copilot-users). Get one:
#   * az login as an in-group user, then:
#       az account get-access-token --resource https://cognitiveservices.azure.com --query accessToken -o tsv
#   * or device-code (see ./test-gateway.sh).
#
# KEYLESS is preferred (no manual token): COPILOT_PROVIDER_TYPE="azure" with NO token —
# the CLI uses DefaultAzureCredential to mint a cognitiveservices token itself.
#
# Usage:  source infra-passthrough/copilot-cli.env.sh
#         copilot -p "explain this repo" --allow-all-tools

export COPILOT_PROVIDER_BASE_URL="https://apim-copilot-poc-pt.azure-api.net/foundry/openai/v1/"
export COPILOT_PROVIDER_TYPE="openai"          # OpenAI-compatible surface exposed by APIM
export COPILOT_PROVIDER_BEARER_TOKEN="PASTE_A_COPILOTUSER_COGNITIVESERVICES_TOKEN_HERE"
export COPILOT_PROVIDER_WIRE_API="completions" # works for gpt-4.1 AND model-router
export COPILOT_MODEL="model-router"            # or "gpt-4.1"

# ----------------------------------------------------------------------------------------------
# KEYLESS (recommended) — paste NOTHING; the CLI acquires the token via DefaultAzureCredential
# (your `az login` as an in-group user, a managed identity, or a service principal):
#   export COPILOT_PROVIDER_TYPE="azure"
#   unset  COPILOT_PROVIDER_API_KEY COPILOT_PROVIDER_BEARER_TOKEN COPILOT_PROVIDER_AZURE_API_VERSION
# WARNING: with the azure type, do NOT set COPILOT_PROVIDER_AZURE_API_VERSION (would switch to the
# classic deployments/...?api-version=... wire format → 404 against this /openai/v1/ gateway).
#
# Responses wire-api: use a REASONING model (gpt-5-mini). model-router /responses is unsupported
# in this PoC (pass-through is data-plane only — see README.md).
# ----------------------------------------------------------------------------------------------

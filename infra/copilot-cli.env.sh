#!/usr/bin/env bash
# Drive the GitHub Copilot CLI (npm i -g @github/copilot) through the governed APIM gateway.
# BYOK mode => NO GitHub login required. The gateway enforces auth/group/limit/metering.
#
# Auth = the DEVELOPER's Entra token (must be a member of the copilot-users group). Get one:
#   * copilotuser (real test): device-code sign-in (see infra/test-gateway.sh), or
#   * any in-group user signed into az:  az account get-access-token --resource https://cognitiveservices.azure.com --query accessToken -o tsv
# The bearer token is STATIC (no refresh) and expires in ~60-90 min — re-export when it does.
#
# Usage:  source infra/copilot-cli.env.sh   # (after pasting a token below)
#         copilot -p "explain this repo" --allow-all-tools
#         copilot                            # interactive

export COPILOT_PROVIDER_BASE_URL="https://apim-copilot-poc.azure-api.net/foundry/openai/v1/"
export COPILOT_PROVIDER_TYPE="openai"          # OpenAI-compatible surface exposed by APIM
export COPILOT_PROVIDER_BEARER_TOKEN="PASTE_A_COPILOTUSER_COGNITIVESERVICES_TOKEN_HERE"
export COPILOT_PROVIDER_WIRE_API="completions" # works for gpt-4.1 AND model-router (auto-routing)
export COPILOT_MODEL="model-router"            # or "gpt-4.1"

# ----------------------------------------------------------------------------------------------
# ALTERNATIVE: COPILOT_PROVIDER_TYPE="azure" — ALSO verified working against this same gateway.
# Two ways, both governed identically by APIM (validated: real 200 + completion through the gate):
#
#   (A) Pasted token — same as above, just flip the type:
#       export COPILOT_PROVIDER_TYPE="azure"
#       export COPILOT_PROVIDER_BEARER_TOKEN="<in-group cognitiveservices Entra token>"
#
#   (B) KEYLESS (recommended) — paste NOTHING. The azure type falls back to DefaultAzureCredential
#       and auto-acquires a token for scope https://cognitiveservices.azure.com/.default (the audience
#       our gateway validates). Picks up `az login` (an in-group user), a managed identity, or an
#       AZURE_CLIENT_ID/TENANT_ID/CLIENT_SECRET service principal. No static-token chore / re-export.
#       export COPILOT_PROVIDER_TYPE="azure"
#       unset  COPILOT_PROVIDER_API_KEY COPILOT_PROVIDER_BEARER_TOKEN
#
#   WARNING: with the azure type, DO NOT set COPILOT_PROVIDER_AZURE_API_VERSION. An api-version switches
#   the CLI to the classic …/openai/deployments/<name>/...?api-version=… wire format, which does NOT
#   match this gateway's /openai/v1/* route -> 404 "Model not found". Leave it unset (versionless v1).
# ----------------------------------------------------------------------------------------------

# NOTE on the Responses wire-api (COPILOT_PROVIDER_WIRE_API="responses"):
#  - The CLI runs STATELESS, so it needs reasoning.encrypted_content back from the model.
#  - WORKS with a REASONING model:  COPILOT_MODEL="gpt-5-mini"  (verified RESPONSES-OK).
#  - FAILS on gpt-4.1        — non-reasoning, has no encrypted reasoning content to return.
#  - FAILS on model-router   — doesn't support encrypted reasoning content (it may route to a
#                              different model each turn; encrypted blobs are model-specific).
#  - "completions" works for ALL models incl. model-router — the simplest default for the CLI.

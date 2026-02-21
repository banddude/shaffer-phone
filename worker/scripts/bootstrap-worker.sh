#!/usr/bin/env bash
set -euo pipefail

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command, $1" >&2
    exit 1
  fi
}

prompt_if_empty() {
  local var_name="$1"
  local prompt_text="$2"
  local default_value="${3:-}"
  local current_value="${!var_name:-}"

  if [[ -n "$current_value" ]]; then
    return
  fi

  if [[ -n "$default_value" ]]; then
    read -r -p "$prompt_text [$default_value]: " current_value
    current_value="${current_value:-$default_value}"
  else
    read -r -p "$prompt_text: " current_value
  fi

  if [[ -z "$current_value" ]]; then
    echo "Value required for $var_name" >&2
    exit 1
  fi

  printf -v "$var_name" '%s' "$current_value"
}

put_secret() {
  local key="$1"
  local value="$2"
  if [[ -z "$value" ]]; then
    return
  fi
  printf "%s" "$value" | npx wrangler secret put "$key" >/dev/null
  echo "Set secret $key"
}

require_cmd npx
require_cmd openssl
require_cmd sed

echo "Shaffer Phone worker bootstrap"

auth_mode="${1:-interactive}"

if [[ -z "${API_TOKEN_VALUE:-}" ]]; then
  API_TOKEN_VALUE="$(openssl rand -hex 24)"
fi

TWILIO_ACCOUNT_SID_VALUE="${TWILIO_ACCOUNT_SID_VALUE:-${TWILIO_ACCOUNT_SID:-}}"
TWILIO_AUTH_TOKEN_VALUE="${TWILIO_AUTH_TOKEN_VALUE:-${TWILIO_AUTH_TOKEN:-}}"
TWILIO_API_KEY_SID_VALUE="${TWILIO_API_KEY_SID_VALUE:-${TWILIO_API_KEY_SID:-}}"
TWILIO_API_KEY_SECRET_VALUE="${TWILIO_API_KEY_SECRET_VALUE:-${TWILIO_API_KEY_SECRET:-}}"
TWILIO_TWIML_APP_SID_VALUE="${TWILIO_TWIML_APP_SID_VALUE:-${TWILIO_TWIML_APP_SID:-}}"
TWILIO_CALLER_ID_VALUE="${TWILIO_CALLER_ID_VALUE:-${TWILIO_CALLER_ID:-}}"
TWILIO_VOICE_CLIENT_IDENTITY_VALUE="${TWILIO_VOICE_CLIENT_IDENTITY_VALUE:-${TWILIO_VOICE_CLIENT_IDENTITY:-office-line}}"
TWILIO_PUSH_CREDENTIAL_SID_VALUE="${TWILIO_PUSH_CREDENTIAL_SID_VALUE:-${TWILIO_PUSH_CREDENTIAL_SID:-}}"

if [[ "$auth_mode" != "noninteractive" ]]; then
  prompt_if_empty API_TOKEN_VALUE "App API token, generated if blank" "$API_TOKEN_VALUE"
  prompt_if_empty TWILIO_ACCOUNT_SID_VALUE "Twilio Account SID"
  prompt_if_empty TWILIO_AUTH_TOKEN_VALUE "Twilio Auth Token"
  prompt_if_empty TWILIO_API_KEY_SID_VALUE "Twilio API Key SID"
  prompt_if_empty TWILIO_API_KEY_SECRET_VALUE "Twilio API Key Secret"

  read -r -p "Twilio TwiML App SID, leave blank if you will create it next: " maybe_twiml
  if [[ -n "$maybe_twiml" ]]; then
    TWILIO_TWIML_APP_SID_VALUE="$maybe_twiml"
  fi

  read -r -p "Twilio Caller ID, for example +13236423969, optional: " maybe_caller
  if [[ -n "$maybe_caller" ]]; then
    TWILIO_CALLER_ID_VALUE="$maybe_caller"
  fi

  read -r -p "Voice identity default [${TWILIO_VOICE_CLIENT_IDENTITY_VALUE}]: " maybe_identity
  if [[ -n "$maybe_identity" ]]; then
    TWILIO_VOICE_CLIENT_IDENTITY_VALUE="$maybe_identity"
  fi

  read -r -p "Twilio Push Credential SID, optional: " maybe_push_sid
  if [[ -n "$maybe_push_sid" ]]; then
    TWILIO_PUSH_CREDENTIAL_SID_VALUE="$maybe_push_sid"
  fi
fi

echo "Setting Cloudflare Worker secrets"
put_secret API_TOKEN "$API_TOKEN_VALUE"
put_secret TWILIO_ACCOUNT_SID "$TWILIO_ACCOUNT_SID_VALUE"
put_secret TWILIO_AUTH_TOKEN "$TWILIO_AUTH_TOKEN_VALUE"
put_secret TWILIO_API_KEY_SID "$TWILIO_API_KEY_SID_VALUE"
put_secret TWILIO_API_KEY_SECRET "$TWILIO_API_KEY_SECRET_VALUE"
put_secret TWILIO_VOICE_CLIENT_IDENTITY "$TWILIO_VOICE_CLIENT_IDENTITY_VALUE"
put_secret TWILIO_TWIML_APP_SID "$TWILIO_TWIML_APP_SID_VALUE"
put_secret TWILIO_CALLER_ID "$TWILIO_CALLER_ID_VALUE"
put_secret TWILIO_PUSH_CREDENTIAL_SID "$TWILIO_PUSH_CREDENTIAL_SID_VALUE"

echo "Deploying worker"
deploy_output="$(npx wrangler deploy 2>&1)"
echo "$deploy_output"

worker_url="$(printf "%s\n" "$deploy_output" | sed -nE 's#^[[:space:]]*(https://[^[:space:]]+)$#\1#p' | tail -n1)"
if [[ -z "$worker_url" ]]; then
  worker_url="https://YOUR_WORKER.workers.dev"
fi

echo ""
echo "Bootstrap complete"
echo "Worker URL, $worker_url"
echo "API Token, $API_TOKEN_VALUE"
echo ""
echo "Next step if you still need Twilio webhooks"
echo "./scripts/configure-twilio-webhooks.sh --worker-url \"$worker_url\" --account-sid \"$TWILIO_ACCOUNT_SID_VALUE\" --auth-token \"$TWILIO_AUTH_TOKEN_VALUE\" --phone-sid YOUR_PHONE_SID --update-worker-secret"
echo ""
echo "Setup link command"
echo "./scripts/generate-setup-link.sh --base-url \"$worker_url\" --api-token \"$API_TOKEN_VALUE\" --identity \"$TWILIO_VOICE_CLIENT_IDENTITY_VALUE\""

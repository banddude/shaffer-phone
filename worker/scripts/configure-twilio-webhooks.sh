#!/usr/bin/env bash
set -euo pipefail

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command, $1" >&2
    exit 1
  fi
}

usage() {
  cat <<USAGE
Usage:
  ./scripts/configure-twilio-webhooks.sh \
    --worker-url https://your-worker.workers.dev \
    --account-sid ACxxxx \
    --auth-token xxxx \
    --phone-sid PNxxxx \
    [--friendly-name "Shaffer Phone Voice App"] \
    [--update-worker-secret]
USAGE
}

require_cmd curl
require_cmd jq

WORKER_URL=""
ACCOUNT_SID=""
AUTH_TOKEN=""
PHONE_SID=""
FRIENDLY_NAME="Shaffer Phone Voice App"
UPDATE_WORKER_SECRET="0"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --worker-url)
      WORKER_URL="$2"
      shift 2
      ;;
    --account-sid)
      ACCOUNT_SID="$2"
      shift 2
      ;;
    --auth-token)
      AUTH_TOKEN="$2"
      shift 2
      ;;
    --phone-sid)
      PHONE_SID="$2"
      shift 2
      ;;
    --friendly-name)
      FRIENDLY_NAME="$2"
      shift 2
      ;;
    --update-worker-secret)
      UPDATE_WORKER_SECRET="1"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown arg, $1" >&2
      usage
      exit 1
      ;;
  esac
done

if [[ -z "$WORKER_URL" || -z "$ACCOUNT_SID" || -z "$AUTH_TOKEN" || -z "$PHONE_SID" ]]; then
  usage
  exit 1
fi

WORKER_URL="${WORKER_URL%/}"

echo "Creating TwiML application"
create_payload="$(curl -sS -u "$ACCOUNT_SID:$AUTH_TOKEN" \
  --data-urlencode "FriendlyName=$FRIENDLY_NAME" \
  --data-urlencode "VoiceUrl=$WORKER_URL/voice-outbound" \
  --data-urlencode "VoiceMethod=POST" \
  "https://api.twilio.com/2010-04-01/Accounts/$ACCOUNT_SID/Applications.json")"

TWIML_APP_SID="$(printf '%s' "$create_payload" | jq -r '.sid // empty')"
if [[ -z "$TWIML_APP_SID" ]]; then
  echo "Failed to create TwiML application" >&2
  echo "$create_payload" >&2
  exit 1
fi

echo "Created TwiML App SID, $TWIML_APP_SID"

echo "Updating Twilio phone webhooks"
update_payload="$(curl -sS -u "$ACCOUNT_SID:$AUTH_TOKEN" -X POST \
  --data-urlencode "VoiceUrl=$WORKER_URL/inbound-client" \
  --data-urlencode "VoiceMethod=POST" \
  --data-urlencode "SmsUrl=$WORKER_URL/sms" \
  --data-urlencode "SmsMethod=POST" \
  "https://api.twilio.com/2010-04-01/Accounts/$ACCOUNT_SID/IncomingPhoneNumbers/$PHONE_SID.json")"

updated_sid="$(printf '%s' "$update_payload" | jq -r '.sid // empty')"
if [[ -z "$updated_sid" ]]; then
  echo "Failed to update incoming phone number" >&2
  echo "$update_payload" >&2
  exit 1
fi

CALLER_ID="$(printf '%s' "$update_payload" | jq -r '.phone_number // empty')"

echo "Twilio phone updated, $updated_sid"
if [[ -n "$CALLER_ID" ]]; then
  echo "Caller ID detected, $CALLER_ID"
fi

if [[ "$UPDATE_WORKER_SECRET" == "1" ]]; then
  require_cmd npx
  printf "%s" "$TWIML_APP_SID" | npx wrangler secret put TWILIO_TWIML_APP_SID >/dev/null
  echo "Updated worker secret, TWILIO_TWIML_APP_SID"

  if [[ -n "$CALLER_ID" ]]; then
    printf "%s" "$CALLER_ID" | npx wrangler secret put TWILIO_CALLER_ID >/dev/null
    echo "Updated worker secret, TWILIO_CALLER_ID"
  fi
fi

echo ""
echo "Done"
echo "TWILIO_TWIML_APP_SID=$TWIML_APP_SID"
echo "TWILIO_CALLER_ID=$CALLER_ID"

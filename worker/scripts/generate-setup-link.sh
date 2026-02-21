#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<USAGE
Usage:
  ./scripts/generate-setup-link.sh \
    --base-url https://your-worker.workers.dev \
    --api-token your_api_token \
    --identity office-line \
    [--scheme shafferphone://setup]
USAGE
}

BASE_URL=""
API_TOKEN=""
IDENTITY=""
SCHEME="shafferphone://setup"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --base-url)
      BASE_URL="$2"
      shift 2
      ;;
    --api-token)
      API_TOKEN="$2"
      shift 2
      ;;
    --identity)
      IDENTITY="$2"
      shift 2
      ;;
    --scheme)
      SCHEME="$2"
      shift 2
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

if [[ -z "$BASE_URL" || -z "$API_TOKEN" || -z "$IDENTITY" ]]; then
  usage
  exit 1
fi

urlencode() {
  node -e 'process.stdout.write(encodeURIComponent(process.argv[1]))' "$1"
}

base_enc="$(urlencode "$BASE_URL")"
token_enc="$(urlencode "$API_TOKEN")"
identity_enc="$(urlencode "$IDENTITY")"

setup_link="$SCHEME?base=$base_enc&token=$token_enc&identity=$identity_enc"

echo "Setup link"
echo "$setup_link"
echo ""
echo "Paste this in the app, Settings, Setup Link, then tap Import Setup Link"

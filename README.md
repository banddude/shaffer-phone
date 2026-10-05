# Shaffer Phone

> **Retired prototype / reference only.** Shaffer business calling, SMS/MMS, voicemail, CallKit, Twilio, recording, and transcription now live in OfficeAdmin. Active replacement work is tracked in `banddude/officeadmin-books` (including phone epic #1094). Do not start new product work in this repository.

Twilio powered iOS business phone app and Cloudflare Worker backend.

## Repo layout

1. `ios-app`, iOS client app, calls, sms, mms, push, contacts, CallKit
2. `worker`, Cloudflare Worker backend, Twilio webhooks, token minting, message sync

## Quick start

1. Open `worker/docs/SELF_HOSTED_SETUP.md`
2. Run `worker/scripts/bootstrap-worker.sh`
3. Run `worker/scripts/configure-twilio-webhooks.sh`
4. Run `worker/scripts/generate-setup-link.sh`
5. In app Settings, paste Setup Link, tap Import Setup Link, then Save and Test Setup

## Before first build

1. In `ios-app/project.yml`, set `DEVELOPMENT_TEAM`
2. Set `PRODUCT_BUNDLE_IDENTIFIER` to your own bundle id
3. In `worker/wrangler.toml`, set your KV namespace id
4. Set Worker secrets with Wrangler

## Security notes

1. Do not commit `.dev.vars`, `.env`, APNS private keys, or Twilio secrets
2. API token and Twilio credentials belong in Cloudflare Worker secrets only

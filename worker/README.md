# Shaffer Phone Worker Backend

Cloudflare Worker backend for Shaffer Phone iOS app, voice calls, sms, and mms.

## Quickstart

1. Open `docs/SELF_HOSTED_SETUP.md`
2. Run `./scripts/bootstrap-worker.sh`
3. Run `./scripts/configure-twilio-webhooks.sh`
4. Run `./scripts/generate-setup-link.sh`
5. Paste setup link in iOS app Settings and tap Import Setup Link

## Core endpoints

1. `POST /sms`, inbound Twilio sms webhook
2. `POST /send-sms`, outbound sms and mms send
3. `GET /api/messages`, app message sync
4. `GET /voice-token`, Twilio Voice SDK access token
5. `POST /register-device`, APNS device registration
6. `POST /client-call-notify`, call notification fanout

## Required secrets

1. `API_TOKEN`
2. `TWILIO_ACCOUNT_SID`
3. `TWILIO_AUTH_TOKEN`
4. `TWILIO_API_KEY_SID`
5. `TWILIO_API_KEY_SECRET`
6. `TWILIO_TWIML_APP_SID`

## Optional secrets

1. `TWILIO_PUSH_CREDENTIAL_SID`
2. `TWILIO_VOICE_CLIENT_IDENTITY`
3. `TWILIO_CALLER_ID`
4. `APNS_KEY_ID`
5. `APNS_TEAM_ID`
6. `APNS_PRIVATE_KEY`

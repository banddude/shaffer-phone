# Shaffer Phone Self Hosted Setup

This guide is for users who bring their own Twilio and Cloudflare accounts.

## What you need

1. Twilio account with a phone number
2. Cloudflare account with Workers enabled
3. Wrangler CLI logged in
4. APNS key details if you want direct APNS message pushes

## Step 1, deploy and seed worker secrets

From this folder:

```bash
./scripts/bootstrap-worker.sh
```

This script sets Worker secrets and deploys your Worker.

## Step 2, wire Twilio webhooks and TwiML app

```bash
./scripts/configure-twilio-webhooks.sh \
  --worker-url https://YOUR_WORKER.workers.dev \
  --account-sid ACxxxxxxxx \
  --auth-token your_auth_token \
  --phone-sid PNxxxxxxxx \
  --update-worker-secret
```

This creates a TwiML app for Voice SDK outbound calls, updates your phone number voice and sms webhooks, and can write the TwiML App SID back to Worker secrets.

## Step 3, generate app setup link

```bash
./scripts/generate-setup-link.sh \
  --base-url https://YOUR_WORKER.workers.dev \
  --api-token YOUR_API_TOKEN \
  --identity office-line
```

Copy the output link.

## Step 4, in iOS app

1. Open Settings
2. Paste Setup Link
3. Tap Import Setup Link
4. Tap Save and Test Setup
5. Grant permissions

## Notes

1. API token is private, do not post it publicly.
2. If you rotate token, regenerate setup link and update app.
3. If calls fail, confirm TWILIO_TWIML_APP_SID and number webhooks are correct.

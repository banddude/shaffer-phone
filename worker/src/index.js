export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    const path = url.pathname.replace(/\/+$/, "") || "/";

    if (request.method === "OPTIONS") {
      return new Response(null, {
        status: 204,
        headers: corsHeaders(),
      });
    } else if (path.startsWith("/media/") && request.method === "GET") {
      return handleGetMedia(request, env);
    } else if (path === "/outbound") {
      return handleOutbound(request, env);
    } else if (path === "/inbound") {
      return handleInboundClient(request, env);
    } else if (path === "/inbound-client") {
      return handleInboundClient(request, env);
    } else if (path === "/voice-outbound") {
      return handleVoiceOutbound(request, env);
    } else if (path === "/voice-token") {
      return handleVoiceToken(request, env);
    } else if (path === "/voice-status" && request.method === "POST") {
      return handleVoiceStatus(request, env);
    } else if (path === "/recording-status" && request.method === "POST") {
      return handleRecordingStatus(request, env);
    } else if (path === "/client-call-notify" && request.method === "POST") {
      return handleClientCallNotify(request, env);
    } else if (path === "/linphone-config") {
      return handleLinphoneConfig();
    } else if (path === "/sms" && request.method === "POST") {
      return handleIncomingSms(request, env);
    } else if (path === "/send-sms" && request.method === "POST") {
      return handleSendSms(request, env);
    } else if (path === "/upload-media" && request.method === "POST") {
      return handleUploadMedia(request, env);
    } else if (path === "/register-device" && request.method === "POST") {
      return handleRegisterDevice(request, env);
    } else if (path === "/unregister-device" && request.method === "POST") {
      return handleUnregisterDevice(request, env);
    } else if (path === "/messages") {
      return handleMessagesUI(request, env);
    } else if (path === "/api/messages") {
      return handleApiMessages(request, env);
    } else if (path === "/api/devices") {
      return handleApiDevices(request, env);
    } else if (path === "/api/recordings") {
      return handleApiRecordings(request, env);
    } else if (path === "/api/voice-calls") {
      return handleApiVoiceCalls(request, env);
    } else {
      return new Response("Twilio TwiML Worker", { status: 200 });
    }
  },
};

// ─── Voice Handlers (existing) ───
const MY_NUMBER = "+13236423969";
const DEFAULT_MEDIA_STORAGE_MAX_BYTES = 900 * 1024 * 1024;
const DEFAULT_VOICE_TOKEN_TTL_SECONDS = 3600;
const DEFAULT_VOICE_CLIENT_IDENTITY = "office-line";
const MAX_REGISTERED_DEVICES = 1000;
const textEncoder = new TextEncoder();

async function handleOutbound(request, env) {
  const formData = await request.formData();
  const toRaw = String(formData.get("To") || "").trim();
  const phoneNumber = normalizePhoneNumber(toRaw);

  const callerId = env.TWILIO_CALLER_ID || MY_NUMBER;
  const recordingStatusCallback = recordingStatusCallbackUrl(request.url);
  const twiml = `<?xml version="1.0" encoding="UTF-8"?>
<Response>
  <Dial callerId="${callerId}" record="record-from-answer-dual" recordingTrack="both" recordingStatusCallback="${recordingStatusCallback}" recordingStatusCallbackEvent="in-progress completed absent">
    <Number>${phoneNumber}</Number>
  </Dial>
</Response>`;

  return new Response(twiml, {
    headers: { "Content-Type": "text/xml" },
  });
}

async function handleInboundClient(request, env) {
  const recordingStatusCallback = recordingStatusCallbackUrl(request.url);
  const statusCallback = callStatusCallbackUrl(request.url);
  const notificationCallback = clientCallNotificationUrl(request.url);
  const clientIdentity = normalizeVoiceIdentity(env.TWILIO_VOICE_CLIENT_IDENTITY, env);
  const twiml = `<?xml version="1.0" encoding="UTF-8"?>
<Response>
  <Dial timeout="30" record="record-from-answer-dual" recordingTrack="both" recordingStatusCallback="${recordingStatusCallback}" recordingStatusCallbackEvent="in-progress completed absent" action="${statusCallback}" method="POST">
    <Client clientNotificationUrl="${escapeXml(notificationCallback)}">${escapeXml(clientIdentity)}</Client>
  </Dial>
</Response>`;
  return new Response(twiml, {
    headers: { "Content-Type": "text/xml" },
  });
}

async function handleVoiceOutbound(request, env) {
  const formData = await request.formData();
  const destinationRaw = String(formData.get("To") || "").trim();
  const callerId = env.TWILIO_CALLER_ID || MY_NUMBER;
  const recordingStatusCallback = recordingStatusCallbackUrl(request.url);
  const statusCallback = callStatusCallbackUrl(request.url);

  if (!destinationRaw) {
    return new Response(`<?xml version="1.0" encoding="UTF-8"?><Response><Say>Missing destination</Say></Response>`, {
      headers: { "Content-Type": "text/xml" },
    });
  }

  let dialNoun = "";
  if (destinationRaw.toLowerCase().startsWith("client:")) {
    const identity = normalizeVoiceIdentity(destinationRaw.split(":")[1], env);
    dialNoun = `<Client>${escapeXml(identity)}</Client>`;
  } else {
    const number = normalizePhoneNumber(destinationRaw);
    dialNoun = `<Number>${escapeXml(number)}</Number>`;
  }

  const twiml = `<?xml version="1.0" encoding="UTF-8"?>
<Response>
  <Dial callerId="${escapeXml(callerId)}" record="record-from-answer-dual" recordingTrack="both" recordingStatusCallback="${recordingStatusCallback}" recordingStatusCallbackEvent="in-progress completed absent" action="${statusCallback}" method="POST">
    ${dialNoun}
  </Dial>
</Response>`;

  return new Response(twiml, {
    headers: { "Content-Type": "text/xml" },
  });
}

async function handleVoiceToken(request, env) {
  const authErr = authCheck(request, env);
  if (authErr) return authErr;

  if (!env.TWILIO_API_KEY_SID || !env.TWILIO_API_KEY_SECRET || !env.TWILIO_TWIML_APP_SID || !env.TWILIO_ACCOUNT_SID) {
    return jsonResponse({
      error: "Missing Twilio voice token env vars",
      required: ["TWILIO_API_KEY_SID", "TWILIO_API_KEY_SECRET", "TWILIO_TWIML_APP_SID", "TWILIO_ACCOUNT_SID"],
    }, 500);
  }

  const url = new URL(request.url);
  const requestedIdentity = (url.searchParams.get("identity") || "").trim();
  const ttlParam = Number.parseInt(url.searchParams.get("ttl") || "", 10);
  const ttl = Number.isFinite(ttlParam) && ttlParam > 60 && ttlParam <= 86400
    ? ttlParam
    : DEFAULT_VOICE_TOKEN_TTL_SECONDS;
  const identity = normalizeVoiceIdentity(requestedIdentity, env);
  const issuedAt = Math.floor(Date.now() / 1000);
  const expiresAt = issuedAt + ttl;

  try {
    const token = await createTwilioVoiceAccessToken(env, identity, issuedAt, expiresAt);
    return jsonResponse({
      token,
      identity,
      ttl,
      issuedAt,
      expiresAt,
      outgoingApplicationSid: env.TWILIO_TWIML_APP_SID,
      pushCredentialSid: env.TWILIO_PUSH_CREDENTIAL_SID || "",
    });
  } catch (error) {
    return jsonResponse({
      error: "Failed to create voice access token",
      detail: String(error || ""),
    }, 500);
  }
}

async function handleVoiceStatus(request, env) {
  const formData = await request.formData();
  const callSid = String(formData.get("CallSid") || "").trim();
  if (!callSid) {
    return new Response("Missing CallSid", { status: 400 });
  }

  const event = {
    callSid,
    parentCallSid: String(formData.get("ParentCallSid") || "").trim(),
    dialCallSid: String(formData.get("DialCallSid") || "").trim(),
    callStatus: String(formData.get("CallStatus") || "").trim(),
    dialCallStatus: String(formData.get("DialCallStatus") || "").trim(),
    dialCallDuration: Number.parseInt(formData.get("DialCallDuration") || "0", 10) || 0,
    direction: String(formData.get("Direction") || "").trim(),
    from: String(formData.get("From") || "").trim(),
    to: String(formData.get("To") || "").trim(),
    accountSid: String(formData.get("AccountSid") || "").trim(),
    raw: Object.fromEntries(formData.entries()),
    timestamp: new Date().toISOString(),
  };

  await storeVoiceCallEvent(env, event);
  return new Response("OK", { status: 200 });
}

function recordingStatusCallbackUrl(requestUrl) {
  const url = new URL(requestUrl);
  return `${url.origin}/recording-status`;
}

function callStatusCallbackUrl(requestUrl) {
  const url = new URL(requestUrl);
  return `${url.origin}/voice-status`;
}

function clientCallNotificationUrl(requestUrl) {
  const url = new URL(requestUrl);
  return `${url.origin}/client-call-notify`;
}

function normalizePhoneNumber(raw) {
  let phoneNumber = String(raw || "").trim();
  if (phoneNumber.includes(":") && !phoneNumber.startsWith("+")) {
    const firstColon = phoneNumber.indexOf(":");
    const scheme = phoneNumber.slice(0, firstColon);
    if (/^[a-zA-Z]+$/.test(scheme)) {
      phoneNumber = phoneNumber.slice(firstColon + 1);
    }
  }
  if (phoneNumber.includes("@")) {
    phoneNumber = phoneNumber.split("@")[0];
  }
  if (phoneNumber.includes(";")) {
    phoneNumber = phoneNumber.split(";")[0];
  }
  if (!phoneNumber.startsWith("+")) {
    phoneNumber = "+" + phoneNumber;
  }
  const digits = phoneNumber.replace(/\D/g, "");
  if (digits.length === 10) {
    return "+1" + digits;
  }
  if (digits.length === 11 && digits.startsWith("1")) {
    return "+" + digits;
  }
  return phoneNumber;
}

function normalizeVoiceIdentity(raw, env) {
  const fallback = String(env.TWILIO_VOICE_CLIENT_IDENTITY || DEFAULT_VOICE_CLIENT_IDENTITY).trim();
  const source = String(raw || fallback).trim();
  const sanitized = source
    .replace(/[^a-zA-Z0-9_.-]/g, "_")
    .slice(0, 121);
  return sanitized || fallback;
}

function escapeXml(value) {
  return String(value || "")
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll("\"", "&quot;")
    .replaceAll("'", "&apos;");
}

async function createTwilioVoiceAccessToken(env, identity, issuedAt, expiresAt) {
  const grants = {
    identity,
    voice: {
      incoming: { allow: true },
      outgoing: {
        application_sid: env.TWILIO_TWIML_APP_SID,
      },
    },
  };
  if (env.TWILIO_PUSH_CREDENTIAL_SID) {
    grants.voice.push_credential_sid = env.TWILIO_PUSH_CREDENTIAL_SID;
  }

  const header = {
    alg: "HS256",
    typ: "JWT",
    cty: "twilio-fpa;v=1",
  };
  const payload = {
    jti: `${env.TWILIO_API_KEY_SID}-${issuedAt}-${crypto.randomUUID()}`,
    iss: env.TWILIO_API_KEY_SID,
    sub: env.TWILIO_ACCOUNT_SID,
    iat: issuedAt,
    exp: expiresAt,
    grants,
  };

  const encodedHeader = base64UrlEncodeJSON(header);
  const encodedPayload = base64UrlEncodeJSON(payload);
  const signingInput = `${encodedHeader}.${encodedPayload}`;
  const signature = await hmacSha256Base64Url(env.TWILIO_API_KEY_SECRET, signingInput);
  return `${signingInput}.${signature}`;
}

function base64UrlEncodeJSON(value) {
  return base64UrlEncodeBytes(textEncoder.encode(JSON.stringify(value)));
}

function base64UrlEncodeBytes(bytes) {
  let binary = "";
  const chunkSize = 0x8000;
  for (let i = 0; i < bytes.length; i += chunkSize) {
    const chunk = bytes.subarray(i, i + chunkSize);
    binary += String.fromCharCode(...chunk);
  }
  return btoa(binary)
    .replaceAll("+", "-")
    .replaceAll("/", "_")
    .replaceAll("=", "");
}

async function hmacSha256Base64Url(secret, input) {
  const key = await crypto.subtle.importKey(
    "raw",
    textEncoder.encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"]
  );
  const signature = await crypto.subtle.sign("HMAC", key, textEncoder.encode(input));
  return base64UrlEncodeBytes(new Uint8Array(signature));
}

function pemToArrayBuffer(pem) {
  const cleaned = String(pem || "")
    .replace(/-----BEGIN PRIVATE KEY-----/g, "")
    .replace(/-----END PRIVATE KEY-----/g, "")
    .replace(/\\n/g, "\n")
    .replace(/\s+/g, "");
  const binary = atob(cleaned);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) {
    bytes[i] = binary.charCodeAt(i);
  }
  return bytes.buffer;
}

function derToJoseSignature(derBytes, outputLength = 64) {
  if (derBytes.length === outputLength) {
    return derBytes;
  }
  if (derBytes[0] !== 0x30) {
    throw new Error("Invalid DER signature format");
  }

  let index = 1;
  let sequenceLength = derBytes[index++];
  if (sequenceLength & 0x80) {
    const byteCount = sequenceLength & 0x7f;
    sequenceLength = 0;
    for (let i = 0; i < byteCount; i++) {
      sequenceLength = (sequenceLength << 8) + derBytes[index++];
    }
  }

  if (derBytes[index++] !== 0x02) {
    throw new Error("Invalid DER signature R marker");
  }
  let rLength = derBytes[index++];
  const r = derBytes.slice(index, index + rLength);
  index += rLength;

  if (derBytes[index++] !== 0x02) {
    throw new Error("Invalid DER signature S marker");
  }
  let sLength = derBytes[index++];
  const s = derBytes.slice(index, index + sLength);

  const half = outputLength / 2;
  const jose = new Uint8Array(outputLength);
  jose.set(r.slice(Math.max(0, r.length - half)), half - Math.min(half, r.length));
  jose.set(s.slice(Math.max(0, s.length - half)), outputLength - Math.min(half, s.length));
  return jose;
}

async function createAPNsProviderToken(env) {
  const issuedAt = Math.floor(Date.now() / 1000);
  const header = { alg: "ES256", kid: env.APNS_KEY_ID, typ: "JWT" };
  const payload = { iss: env.APNS_TEAM_ID, iat: issuedAt };

  const encodedHeader = base64UrlEncodeJSON(header);
  const encodedPayload = base64UrlEncodeJSON(payload);
  const signingInput = `${encodedHeader}.${encodedPayload}`;

  const key = await crypto.subtle.importKey(
    "pkcs8",
    pemToArrayBuffer(env.APNS_PRIVATE_KEY),
    { name: "ECDSA", namedCurve: "P-256" },
    false,
    ["sign"]
  );
  const derSignature = new Uint8Array(await crypto.subtle.sign(
    { name: "ECDSA", hash: "SHA-256" },
    key,
    textEncoder.encode(signingInput)
  ));
  const joseSignature = derToJoseSignature(derSignature, 64);
  const encodedSignature = base64UrlEncodeBytes(joseSignature);
  return `${signingInput}.${encodedSignature}`;
}

function handleLinphoneConfig() {
  return jsonResponse({
    error: "This endpoint is deprecated",
    replacement: "Use /voice-token, /voice-outbound, /inbound-client, /sms, /send-sms, /upload-media",
  }, 410);
}

// ─── SMS/MMS Handlers ───

function authCheck(request, env) {
  const url = new URL(request.url);
  const token = url.searchParams.get("token") ||
    request.headers.get("Authorization")?.replace("Bearer ", "") ||
    getCookie(request, "api_token");
  if (!env.API_TOKEN || token !== env.API_TOKEN) {
    return new Response("Unauthorized", { status: 401 });
  }
  return null;
}

function getCookie(request, name) {
  const cookies = request.headers.get("Cookie") || "";
  const match = cookies.match(new RegExp(`(?:^|;\\s*)${name}=([^;]*)`));
  return match ? decodeURIComponent(match[1]) : null;
}

function normalizeDeviceToken(raw) {
  return String(raw || "").replace(/[^a-fA-F0-9]/g, "").toLowerCase();
}

function normalizeDeviceId(raw) {
  const cleaned = String(raw || "")
    .trim()
    .replace(/[^a-zA-Z0-9._-]/g, "_")
    .slice(0, 128);
  return cleaned || crypto.randomUUID();
}

function normalizePushEnvironment(raw) {
  const value = String(raw || "").toLowerCase();
  if (value === "production") return "production";
  return "development";
}

async function handleRegisterDevice(request, env) {
  const authErr = authCheck(request, env);
  if (authErr) return authErr;

  let payload;
  try {
    payload = await request.json();
  } catch {
    return jsonResponse({ error: "Invalid JSON" }, 400);
  }

  const token = normalizeDeviceToken(payload.token);
  if (token.length < 64) {
    return jsonResponse({ error: "Invalid device token" }, 400);
  }

  const deviceId = normalizeDeviceId(payload.deviceId);
  const bundleId = String(payload.bundleId || env.APNS_BUNDLE_ID || "").trim();
  if (!bundleId) {
    return jsonResponse({ error: "Missing bundleId" }, 400);
  }

  const device = {
    id: deviceId,
    token,
    bundleId,
    environment: normalizePushEnvironment(payload.environment || env.APNS_DEFAULT_ENV),
    voiceIdentity: normalizeVoiceIdentity(payload.voiceIdentity || env.TWILIO_VOICE_CLIENT_IDENTITY, env),
    platform: "ios",
    locale: String(payload.locale || ""),
    appVersion: String(payload.appVersion || ""),
    updatedAt: new Date().toISOString(),
  };

  await env.MESSAGES.put(`device:${deviceId}`, JSON.stringify(device));
  await touchDeviceIndex(env, deviceId);

  return jsonResponse({
    success: true,
    deviceId,
    environment: device.environment,
  });
}

async function handleUnregisterDevice(request, env) {
  const authErr = authCheck(request, env);
  if (authErr) return authErr;

  let payload;
  try {
    payload = await request.json();
  } catch {
    return jsonResponse({ error: "Invalid JSON" }, 400);
  }

  const deviceId = normalizeDeviceId(payload.deviceId);
  await env.MESSAGES.delete(`device:${deviceId}`);
  await removeDeviceFromIndex(env, deviceId);
  return jsonResponse({ success: true, deviceId });
}

async function handleApiDevices(request, env) {
  const authErr = authCheck(request, env);
  if (authErr) return authErr;
  const devices = await getRegisteredDevices(env);
  return jsonResponse({ count: devices.length, devices });
}

async function touchDeviceIndex(env, deviceId) {
  const key = "index:devices";
  const existing = (await env.MESSAGES.get(key, "json")) || [];
  const filtered = existing.filter((value) => value !== deviceId);
  filtered.push(deviceId);
  if (filtered.length > MAX_REGISTERED_DEVICES) {
    filtered.splice(0, filtered.length - MAX_REGISTERED_DEVICES);
  }
  await env.MESSAGES.put(key, JSON.stringify(filtered));
}

async function removeDeviceFromIndex(env, deviceId) {
  const key = "index:devices";
  const existing = (await env.MESSAGES.get(key, "json")) || [];
  const filtered = existing.filter((value) => value !== deviceId);
  await env.MESSAGES.put(key, JSON.stringify(filtered));
}

async function getRegisteredDevices(env) {
  const index = (await env.MESSAGES.get("index:devices", "json")) || [];
  if (!Array.isArray(index) || index.length === 0) {
    return [];
  }

  const results = await Promise.all(index.map(id => env.MESSAGES.get(`device:${id}`, "json")));
  return results.filter(device => device && device.token && device.bundleId).reverse();
}

function extractVoiceIdentityFromPayload(payload, env) {
  const rawTo = String(payload.twi_to || payload.To || payload.to || "").trim();
  if (rawTo.toLowerCase().startsWith("client:")) {
    return normalizeVoiceIdentity(rawTo.slice("client:".length), env);
  }
  if (rawTo) {
    return normalizeVoiceIdentity(rawTo, env);
  }
  return normalizeVoiceIdentity(env.TWILIO_VOICE_CLIENT_IDENTITY, env);
}

async function handleClientCallNotify(request, env) {
  let payload = {};
  const contentType = String(request.headers.get("content-type") || "").toLowerCase();

  try {
    if (contentType.includes("application/json")) {
      payload = await request.json();
    } else {
      const formData = await request.formData();
      payload = Object.fromEntries(formData.entries());
    }
  } catch {
    return jsonResponse({ error: "Invalid payload" }, 400);
  }

  const identity = extractVoiceIdentityFromPayload(payload, env);
  if (!identity) {
    return jsonResponse({ error: "Missing voice identity" }, 400);
  }

  const devices = await getRegisteredDevices(env);
  const targets = devices.filter((device) => !device.voiceIdentity || device.voiceIdentity === identity);
  if (targets.length === 0) {
    return jsonResponse({ ok: true, identity, delivered: 0, failed: 0, skipped: "no_matching_devices" });
  }

  const result = await sendVoiceCallPushNotifications(env, request.url, payload, targets, identity);
  return jsonResponse({
    ok: true,
    identity,
    delivered: result.delivered,
    failed: result.failed,
  });
}

async function sendVoiceCallPushNotifications(env, requestUrl, payload, devices, identity) {
  if (!env.APNS_KEY_ID || !env.APNS_TEAM_ID || !env.APNS_PRIVATE_KEY) {
    return { skipped: "missing_apns_credentials", delivered: 0, failed: devices.length };
  }

  const authToken = await createAPNsProviderToken(env);
  const baseHeaders = {
    Authorization: `bearer ${authToken}`,
    "apns-push-type": "background",
    "apns-priority": "5",
    "apns-expiration": "0",
  };

  const normalizedPayload = {};
  for (const [key, value] of Object.entries(payload || {})) {
    normalizedPayload[key] = typeof value === "string" ? value : String(value ?? "");
  }

  const apnsPayload = {
    aps: {
      "content-available": 1,
    },
    ...normalizedPayload,
    type: "voice_call",
    voice_identity: identity,
  };

  const invalidDeviceIds = [];
  const results = await Promise.allSettled(devices.map(async (device) => {
    const host = device.environment === "production"
      ? "api.push.apple.com"
      : "api.sandbox.push.apple.com";
    const response = await fetch(`https://${host}/3/device/${device.token}`, {
      method: "POST",
      headers: {
        ...baseHeaders,
        "apns-topic": device.bundleId,
      },
      body: JSON.stringify(apnsPayload),
    });

    if (response.status === 410 || response.status === 400) {
      invalidDeviceIds.push(device.id);
    }
    if (!response.ok) {
      const errorText = await response.text();
      throw new Error(`apns_${response.status}:${errorText}`);
    }
    return true;
  }));

  if (invalidDeviceIds.length > 0) {
    for (const id of invalidDeviceIds) {
      await env.MESSAGES.delete(`device:${id}`);
      await removeDeviceFromIndex(env, id);
    }
  }

  const delivered = results.filter((result) => result.status === "fulfilled").length;
  const failed = results.length - delivered;
  const callSid = String(payload?.twi_call_sid || payload?.CallSid || payload?.call_sid || payload?.callSid || crypto.randomUUID());

  await storePushEvent(env, {
    type: "voice_call",
    delivered,
    failed,
    number: String(payload?.twi_from || payload?.From || ""),
    messageId: callSid,
    timestamp: new Date().toISOString(),
    requestOrigin: new URL(requestUrl).origin,
  });

  return { delivered, failed };
}

async function sendSMSPushNotifications(env, requestUrl, payload) {
  if (!env.APNS_KEY_ID || !env.APNS_TEAM_ID || !env.APNS_PRIVATE_KEY) {
    return { skipped: "missing_apns_credentials" };
  }

  const devices = await getRegisteredDevices(env);
  if (devices.length === 0) {
    return { skipped: "no_registered_devices" };
  }

  const authToken = await createAPNsProviderToken(env);
  const baseHeaders = {
    Authorization: `bearer ${authToken}`,
    "apns-push-type": "alert",
    "apns-priority": "10",
    "apns-expiration": "0",
  };

  const alertBody = payload.body && payload.body.trim().length > 0
    ? payload.body.trim().slice(0, 180)
    : (payload.hasMedia ? "Media message" : "New message");

  const apnsPayload = {
    aps: {
      alert: {
        title: formatPushNumber(payload.number),
        body: alertBody,
      },
      sound: "default",
    },
    type: "sms",
    sms_number: payload.number,
    sms_message_id: payload.messageId,
    has_media: payload.hasMedia,
  };

  const invalidDeviceIds = [];
  const results = await Promise.allSettled(devices.map(async (device) => {
    const host = device.environment === "production"
      ? "api.push.apple.com"
      : "api.sandbox.push.apple.com";
    const response = await fetch(`https://${host}/3/device/${device.token}`, {
      method: "POST",
      headers: {
        ...baseHeaders,
        "apns-topic": device.bundleId,
      },
      body: JSON.stringify(apnsPayload),
    });

    if (response.status === 410 || response.status === 400) {
      invalidDeviceIds.push(device.id);
    }
    if (!response.ok) {
      const errorText = await response.text();
      throw new Error(`apns_${response.status}:${errorText}`);
    }
    return true;
  }));

  if (invalidDeviceIds.length > 0) {
    for (const id of invalidDeviceIds) {
      await env.MESSAGES.delete(`device:${id}`);
      await removeDeviceFromIndex(env, id);
    }
  }

  const delivered = results.filter((result) => result.status === "fulfilled").length;
  const failed = results.length - delivered;
  await storePushEvent(env, {
    type: "sms",
    delivered,
    failed,
    number: payload.number,
    messageId: payload.messageId,
    timestamp: new Date().toISOString(),
    requestOrigin: new URL(requestUrl).origin,
  });
  return { delivered, failed };
}

async function storePushEvent(env, event) {
  const key = `push_event:${event.messageId}:${Date.now()}`;
  await env.MESSAGES.put(key, JSON.stringify(event));
}

function formatPushNumber(number) {
  const digits = String(number || "").replace(/\D/g, "");
  if (digits.length === 11 && digits.startsWith("1")) {
    return `(${digits.slice(1, 4)}) ${digits.slice(4, 7)}-${digits.slice(7)}`;
  }
  if (digits.length === 10) {
    return `(${digits.slice(0, 3)}) ${digits.slice(3, 6)}-${digits.slice(6)}`;
  }
  return number || "New Message";
}

async function handleIncomingSms(request, env) {
  const formData = await request.formData();
  const from = formData.get("From") || "";
  const to = formData.get("To") || "";
  const body = formData.get("Body") || "";
  const numMedia = parseInt(formData.get("NumMedia") || "0", 10);
  const messageSid = formData.get("MessageSid") || "";

  const media = [];
  for (let i = 0; i < numMedia; i++) {
    const twilioMediaUrl = formData.get(`MediaUrl${i}`);
    const mediaType = formData.get(`MediaContentType${i}`) || "application/octet-stream";
    if (twilioMediaUrl) {
      const persisted = await persistInboundMedia(env, twilioMediaUrl, mediaType, messageSid, i, request.url);
      if (persisted) {
        media.push(persisted);
      } else {
        media.push({ url: twilioMediaUrl, contentType: mediaType });
      }
    }
  }

  const msg = {
    id: messageSid || crypto.randomUUID(),
    direction: "inbound",
    from,
    to,
    body,
    media,
    timestamp: new Date().toISOString(),
  };

  await storeMessage(env, from, msg);
  if (numMedia > 0) {
    await enforceMediaStorageLimit(env);
  }
  try {
    await sendSMSPushNotifications(env, request.url, {
      number: normalizeNumber(from),
      body: String(body || ""),
      messageId: msg.id,
      hasMedia: media.length > 0,
    });
  } catch (error) {
    // Keep webhook response successful even if APNs delivery fails.
  }

  const twiml = `<?xml version="1.0" encoding="UTF-8"?><Response/>`;
  return new Response(twiml, {
    headers: { "Content-Type": "text/xml" },
  });
}

async function handleSendSms(request, env) {
  const authErr = authCheck(request, env);
  if (authErr) return authErr;

  let payload;
  try {
    payload = await request.json();
  } catch {
    return jsonResponse({ error: "Invalid JSON" }, 400);
  }

  const { to, body, mediaUrl, mediaUrls } = payload;
  const normalizedBody = typeof body === "string" ? body.trim() : "";

  if (!to || (!normalizedBody && !mediaUrl && !(Array.isArray(mediaUrls) && mediaUrls.length > 0))) {
    return jsonResponse({ error: "Missing 'to' and either 'body' or media" }, 400);
  }

  const twilioParams = new URLSearchParams();
  twilioParams.set("From", env.TWILIO_CALLER_ID || MY_NUMBER);
  twilioParams.set("To", to);
  twilioParams.set("Body", normalizedBody || " ");

  const allMediaUrls = [];
  if (mediaUrl) allMediaUrls.push(mediaUrl);
  if (Array.isArray(mediaUrls)) {
    for (const url of mediaUrls) {
      if (typeof url === "string" && url.trim()) {
        allMediaUrls.push(url.trim());
      }
    }
  }

  for (const media of allMediaUrls.slice(0, 10)) {
    twilioParams.append("MediaUrl", media);
  }

  const twilioUrl = `https://api.twilio.com/2010-04-01/Accounts/${env.TWILIO_ACCOUNT_SID}/Messages.json`;
  const twilioAuth = btoa(`${env.TWILIO_ACCOUNT_SID}:${env.TWILIO_AUTH_TOKEN}`);

  const resp = await fetch(twilioUrl, {
    method: "POST",
    headers: {
      "Authorization": `Basic ${twilioAuth}`,
      "Content-Type": "application/x-www-form-urlencoded",
    },
    body: twilioParams.toString(),
  });

  const result = await resp.json();

  if (!resp.ok) {
    return jsonResponse({ error: result.message || "Twilio API error", detail: result }, resp.status);
  }

  const media = await resolveMediaMetadata(env, allMediaUrls, request.url);

  const msg = {
    id: result.sid || crypto.randomUUID(),
    direction: "outbound",
    from: env.TWILIO_CALLER_ID || MY_NUMBER,
    to,
    body,
    media,
    timestamp: new Date().toISOString(),
  };

  await storeMessage(env, to, msg);

  return jsonResponse({ success: true, sid: result.sid });
}

async function handleUploadMedia(request, env) {
  const authErr = authCheck(request, env);
  if (authErr) return authErr;

  const formData = await request.formData();
  const files = formData.getAll("files");
  if (!files || files.length === 0) {
    return jsonResponse({ error: "No files uploaded" }, 400);
  }

  const uploaded = [];
  for (const file of files) {
    if (!(file instanceof File)) continue;
    const contentType = file.type || "application/octet-stream";
    const ext = extensionForContentType(contentType, file.name);
    const id = crypto.randomUUID();
    const key = `media:${id}${ext ? "." + ext : ""}`;
    const bytes = await file.arrayBuffer();

    await env.MESSAGES.put(key, bytes, {
      metadata: {
        contentType,
        fileName: file.name || key,
        createdAt: new Date().toISOString(),
        size: bytes.byteLength,
      },
    });

    uploaded.push({
      key,
      url: absoluteMediaURL(request.url, key),
      contentType,
      fileName: file.name || key,
      size: bytes.byteLength,
    });
  }

  if (uploaded.length === 0) {
    return jsonResponse({ error: "No supported files uploaded" }, 400);
  }

  await enforceMediaStorageLimit(env);

  return jsonResponse({ success: true, files: uploaded });
}

async function handleGetMedia(request, env) {
  const url = new URL(request.url);
  const key = `media:${url.pathname.replace(/^\/media\//, "")}`;
  const { value, metadata } = await env.MESSAGES.getWithMetadata(key, "arrayBuffer");
  if (!value) {
    return new Response("Not found", { status: 404, headers: corsHeaders() });
  }

  const headers = corsHeaders();
  headers["Content-Type"] = metadata?.contentType || "application/octet-stream";
  headers["Cache-Control"] = "public, max-age=31536000, immutable";
  if (metadata?.fileName) {
    headers["Content-Disposition"] = `inline; filename="${metadata.fileName}"`;
  }

  return new Response(value, { status: 200, headers });
}

async function handleApiMessages(request, env) {
  const authErr = authCheck(request, env);
  if (authErr) return authErr;

  const url = new URL(request.url);
  const number = url.searchParams.get("number");

  if (number) {
    const messages = await getMessages(env, number);
    return jsonResponse({ number, messages });
  }

  // Return all conversations
  const conversations = await getAllConversations(env);
  return jsonResponse({ conversations });
}

async function handleMessagesUI(request, env) {
  const authErr = authCheck(request, env);
  if (authErr) return authErr;

  const url = new URL(request.url);
  const token = url.searchParams.get("token") || "";

  return new Response(messagesHTML(token), {
    headers: { "Content-Type": "text/html" },
  });
}

async function handleRecordingStatus(request, env) {
  const formData = await request.formData();
  const event = {
    recordingSid: String(formData.get("RecordingSid") || "").trim(),
    callSid: String(formData.get("CallSid") || "").trim(),
    recordingStatus: String(formData.get("RecordingStatus") || "").trim(),
    recordingUrl: String(formData.get("RecordingUrl") || "").trim(),
    recordingDuration: Number.parseInt(formData.get("RecordingDuration") || "0", 10) || 0,
    recordingChannels: Number.parseInt(formData.get("RecordingChannels") || "0", 10) || 0,
    source: String(formData.get("RecordingSource") || "").trim(),
    from: String(formData.get("From") || "").trim(),
    to: String(formData.get("To") || "").trim(),
    accountSid: String(formData.get("AccountSid") || "").trim(),
    timestamp: new Date().toISOString(),
  };

  if (!event.recordingSid) {
    return new Response("Missing RecordingSid", { status: 400 });
  }

  await storeRecordingEvent(env, event);
  return new Response("OK", { status: 200 });
}

async function handleApiRecordings(request, env) {
  const authErr = authCheck(request, env);
  if (authErr) return authErr;

  const url = new URL(request.url);
  const recordingSid = (url.searchParams.get("recordingSid") || "").trim();
  const callSid = (url.searchParams.get("callSid") || "").trim();
  const limitParam = Number.parseInt(url.searchParams.get("limit") || "100", 10);
  const limit = Math.min(Math.max(limitParam || 100, 1), 500);

  if (recordingSid) {
    const one = await env.MESSAGES.get(`recording:${recordingSid}`, "json");
    return jsonResponse({ recording: one || null });
  }

  const recordings = await getRecordings(env, limit, callSid);
  return jsonResponse({ recordings });
}

async function handleApiVoiceCalls(request, env) {
  const authErr = authCheck(request, env);
  if (authErr) return authErr;

  const url = new URL(request.url);
  const callSid = (url.searchParams.get("callSid") || "").trim();
  const limitParam = Number.parseInt(url.searchParams.get("limit") || "100", 10);
  const limit = Math.min(Math.max(limitParam || 100, 1), 500);

  if (callSid) {
    const one = await env.MESSAGES.get(`voice_call:${callSid}`, "json");
    return jsonResponse({ call: one || null });
  }

  const calls = await getVoiceCalls(env, limit);
  return jsonResponse({ calls });
}

// ─── KV Storage ───

async function storeVoiceCallEvent(env, event) {
  const key = `voice_call:${event.callSid}`;
  const existing = (await env.MESSAGES.get(key, "json")) || {
    callSid: event.callSid,
    events: [],
  };

  existing.callSid = event.callSid;
  existing.parentCallSid = event.parentCallSid || existing.parentCallSid || "";
  existing.dialCallSid = event.dialCallSid || existing.dialCallSid || "";
  existing.callStatus = event.callStatus || existing.callStatus || "";
  existing.dialCallStatus = event.dialCallStatus || existing.dialCallStatus || "";
  existing.dialCallDuration = event.dialCallDuration || existing.dialCallDuration || 0;
  existing.direction = event.direction || existing.direction || "";
  existing.from = event.from || existing.from || "";
  existing.to = event.to || existing.to || "";
  existing.accountSid = event.accountSid || existing.accountSid || "";
  existing.updatedAt = event.timestamp;

  if (!Array.isArray(existing.events)) {
    existing.events = [];
  }
  existing.events.push(event);
  if (existing.events.length > 50) {
    existing.events.splice(0, existing.events.length - 50);
  }

  await env.MESSAGES.put(key, JSON.stringify(existing));
  await touchVoiceCallIndex(env, event.callSid);
}

async function touchVoiceCallIndex(env, callSid) {
  const key = "index:voice_calls";
  const existing = (await env.MESSAGES.get(key, "json")) || [];
  const filtered = existing.filter((value) => value !== callSid);
  filtered.push(callSid);
  if (filtered.length > 5000) {
    filtered.splice(0, filtered.length - 5000);
  }
  await env.MESSAGES.put(key, JSON.stringify(filtered));
}

async function getVoiceCalls(env, limit = 100) {
  const index = (await env.MESSAGES.get("index:voice_calls", "json")) || [];
  if (!Array.isArray(index) || index.length === 0) {
    return [];
  }

  const slice = index.slice(-limit).reverse();
  const results = await Promise.all(slice.map(callSid => env.MESSAGES.get(`voice_call:${callSid}`, "json")));
  return results.filter(Boolean);
}

async function storeRecordingEvent(env, event) {
  const key = `recording:${event.recordingSid}`;
  const existing = (await env.MESSAGES.get(key, "json")) || {
    recordingSid: event.recordingSid,
    events: [],
  };

  existing.recordingSid = event.recordingSid;
  existing.callSid = event.callSid || existing.callSid || "";
  existing.from = event.from || existing.from || "";
  existing.to = event.to || existing.to || "";
  existing.accountSid = event.accountSid || existing.accountSid || "";
  existing.recordingUrl = event.recordingUrl || existing.recordingUrl || "";
  existing.recordingDuration = event.recordingDuration || existing.recordingDuration || 0;
  existing.recordingChannels = event.recordingChannels || existing.recordingChannels || 0;
  existing.recordingStatus = event.recordingStatus || existing.recordingStatus || "";
  existing.source = event.source || existing.source || "";
  existing.updatedAt = event.timestamp;

  if (!Array.isArray(existing.events)) {
    existing.events = [];
  }
  existing.events.push(event);
  if (existing.events.length > 20) {
    existing.events.splice(0, existing.events.length - 20);
  }

  await env.MESSAGES.put(key, JSON.stringify(existing));
  await touchRecordingIndex(env, event.recordingSid);
}

async function touchRecordingIndex(env, recordingSid) {
  const key = "index:recordings";
  const existing = (await env.MESSAGES.get(key, "json")) || [];
  const filtered = existing.filter((value) => value !== recordingSid);
  filtered.push(recordingSid);
  if (filtered.length > 5000) {
    filtered.splice(0, filtered.length - 5000);
  }
  await env.MESSAGES.put(key, JSON.stringify(filtered));
}

async function getRecordings(env, limit = 100, callSid = "") {
  const index = (await env.MESSAGES.get("index:recordings", "json")) || [];
  if (!Array.isArray(index) || index.length === 0) {
    return [];
  }

  const slice = index.slice(-limit).reverse();
  const results = await Promise.all(slice.map(recordingSid => env.MESSAGES.get(`recording:${recordingSid}`, "json")));
  const filtered = results.filter(Boolean);
  if (callSid) {
    return filtered.filter(recording => recording.callSid === callSid);
  }
  return filtered;
}

async function storeMessage(env, otherNumber, msg) {
  const normalized = normalizeNumber(otherNumber);
  const key = `conv:${normalized}`;

  const existing = await env.MESSAGES.get(key, "json");
  const messages = existing || [];
  messages.push(msg);

  // Keep last 500 messages per conversation
  if (messages.length > 500) {
    messages.splice(0, messages.length - 500);
  }

  await env.MESSAGES.put(key, JSON.stringify(messages));

  // Update conversation index
  const indexKey = "index:conversations";
  const index = (await env.MESSAGES.get(indexKey, "json")) || [];
  if (!index.includes(normalized)) {
    index.push(normalized);
    await env.MESSAGES.put(indexKey, JSON.stringify(index));
  }
}

async function getMessages(env, number) {
  const normalized = normalizeNumber(number);
  const key = `conv:${normalized}`;
  return (await env.MESSAGES.get(key, "json")) || [];
}

async function getAllConversations(env) {
  const indexKey = "index:conversations";
  const index = (await env.MESSAGES.get(indexKey, "json")) || [];

  const results = await Promise.all(index.map(async (number) => {
    const messages = await getMessages(env, number);
    if (messages.length > 0) {
      const last = messages[messages.length - 1];
      return {
        number,
        lastMessage: last.body,
        lastTimestamp: last.timestamp,
        messageCount: messages.length,
        hasMedia: messages.some(m => m.media && m.media.length > 0),
      };
    }
    return null;
  }));

  const conversations = results.filter(Boolean);
  conversations.sort((a, b) => b.lastTimestamp.localeCompare(a.lastTimestamp));
  return conversations;
}

function normalizeNumber(num) {
  const digits = num.replace(/\D/g, "");
  if (digits.length === 10) return "+1" + digits;
  if (digits.length === 11 && digits.startsWith("1")) return "+" + digits;
  if (num.startsWith("+")) return num;
  return "+" + digits;
}

function jsonResponse(data, status = 200) {
  return new Response(JSON.stringify(data), {
    status,
    headers: {
      "Content-Type": "application/json",
      ...corsHeaders(),
    },
  });
}

function corsHeaders() {
  return {
    "Access-Control-Allow-Origin": "*",
    "Access-Control-Allow-Methods": "GET,POST,OPTIONS",
    "Access-Control-Allow-Headers": "Content-Type, Authorization",
  };
}

function absoluteMediaURL(requestUrl, key) {
  const base = new URL(requestUrl);
  return `${base.origin}/media/${key.replace(/^media:/, "")}`;
}

function extensionForContentType(contentType, fileName = "") {
  const explicit = fileName.includes(".") ? fileName.split(".").pop() : "";
  if (explicit) return explicit.toLowerCase();
  const map = {
    "image/jpeg": "jpg",
    "image/png": "png",
    "image/gif": "gif",
    "image/webp": "webp",
    "video/mp4": "mp4",
    "video/quicktime": "mov",
    "video/3gpp": "3gp",
    "video/3gpp2": "3g2",
    "video/webm": "webm",
    "audio/mpeg": "mp3",
    "audio/mp4": "m4a",
    "audio/wav": "wav",
  };
  return map[contentType.toLowerCase()] || "bin";
}

async function persistInboundMedia(env, twilioMediaUrl, contentType, messageSid, index, requestUrl) {
  try {
    const twilioAuth = btoa(`${env.TWILIO_ACCOUNT_SID}:${env.TWILIO_AUTH_TOKEN}`);
    const resp = await fetch(twilioMediaUrl, {
      headers: {
        Authorization: `Basic ${twilioAuth}`,
        Accept: "video/mp4,video/*;q=0.9,image/*;q=0.9,*/*;q=0.8",
      },
    });
    if (!resp.ok) {
      return null;
    }

    const bytes = await resp.arrayBuffer();
    const resolvedContentType = (resp.headers.get("Content-Type") || contentType || "application/octet-stream")
      .split(";")[0]
      .trim()
      .toLowerCase();
    const ext = extensionForContentType(resolvedContentType);
    const safeSid = (messageSid || crypto.randomUUID()).replace(/[^a-zA-Z0-9]/g, "");
    const key = `media:inbound_${safeSid}_${index}${ext ? "." + ext : ""}`;

    await env.MESSAGES.put(key, bytes, {
      metadata: {
        contentType: resolvedContentType,
        source: twilioMediaUrl,
        createdAt: new Date().toISOString(),
        size: bytes.byteLength,
      },
    });

    return {
      url: absoluteMediaURL(requestUrl, key),
      contentType: resolvedContentType,
    };
  } catch {
    return null;
  }
}

async function resolveMediaMetadata(env, mediaUrls, requestUrl) {
  const result = [];
  const ownOrigin = new URL(requestUrl).origin;
  for (const mediaUrl of mediaUrls.slice(0, 10)) {
    let contentType = "application/octet-stream";
    try {
      const url = new URL(mediaUrl);
      if (url.origin === ownOrigin && url.pathname.startsWith("/media/")) {
        const key = `media:${url.pathname.replace(/^\/media\//, "")}`;
        const metadataResult = await env.MESSAGES.getWithMetadata(key, "arrayBuffer");
        if (metadataResult?.metadata?.contentType) {
          contentType = metadataResult.metadata.contentType;
        }
      }
    } catch {
      // Keep default content type.
    }
    result.push({ url: mediaUrl, contentType });
  }
  return result;
}

function mediaStorageLimitBytes(env) {
  const configured = Number.parseInt(env.MEDIA_STORAGE_MAX_BYTES || "", 10);
  if (Number.isFinite(configured) && configured > 0) {
    return configured;
  }
  return DEFAULT_MEDIA_STORAGE_MAX_BYTES;
}

async function enforceMediaStorageLimit(env) {
  const maxBytes = mediaStorageLimitBytes(env);
  const mediaEntries = await listMediaEntries(env);
  if (mediaEntries.length === 0) {
    return;
  }

  let totalBytes = mediaEntries.reduce((sum, entry) => sum + entry.size, 0);
  if (totalBytes <= maxBytes) {
    return;
  }

  mediaEntries.sort((a, b) => {
    if (a.createdAtMs !== b.createdAtMs) {
      return a.createdAtMs - b.createdAtMs;
    }
    return a.name.localeCompare(b.name);
  });

  const deletedKeys = [];
  for (const entry of mediaEntries) {
    if (totalBytes <= maxBytes) {
      break;
    }
    await env.MESSAGES.delete(entry.name);
    totalBytes = Math.max(0, totalBytes - entry.size);
    deletedKeys.push(entry.name);
  }

  if (deletedKeys.length > 0) {
    await removeDeletedMediaReferences(env, deletedKeys);
  }
}

async function listMediaEntries(env) {
  let cursor;
  const entries = [];

  do {
    const page = await env.MESSAGES.list({ prefix: "media:", cursor, limit: 1000 });
    for (const key of page.keys) {
      const metadata = key.metadata || {};
      let size = Number.parseInt(metadata.size || "0", 10);
      if (!Number.isFinite(size) || size < 0) {
        size = 0;
      }
      const createdAtMs = Date.parse(metadata.createdAt || "") || 0;
      entries.push({
        name: key.name,
        size,
        createdAtMs,
      });
    }
    cursor = page.list_complete ? undefined : page.cursor;
  } while (cursor);

  for (const entry of entries) {
    if (entry.size > 0) {
      continue;
    }
    const item = await env.MESSAGES.getWithMetadata(entry.name, "arrayBuffer");
    if (item?.value) {
      entry.size = item.value.byteLength;
      if (entry.createdAtMs === 0) {
        entry.createdAtMs = Date.parse(item.metadata?.createdAt || "") || 0;
      }
    }
  }

  return entries;
}

async function removeDeletedMediaReferences(env, deletedKeys) {
  if (!deletedKeys.length) {
    return;
  }

  const deletedMediaIds = new Set(deletedKeys.map((key) => key.replace(/^media:/, "")));
  let cursor;

  do {
    const page = await env.MESSAGES.list({ prefix: "conv:", cursor, limit: 1000 });
    for (const key of page.keys) {
      const messages = await env.MESSAGES.get(key.name, "json");
      if (!Array.isArray(messages)) {
        continue;
      }

      let changed = false;
      for (const message of messages) {
        if (!Array.isArray(message.media) || message.media.length === 0) {
          continue;
        }

        const filteredMedia = message.media.filter((item) => {
          const mediaId = mediaIdFromUrl(item?.url || "");
          return !mediaId || !deletedMediaIds.has(mediaId);
        });

        if (filteredMedia.length !== message.media.length) {
          message.media = filteredMedia;
          changed = true;
        }
      }

      if (changed) {
        await env.MESSAGES.put(key.name, JSON.stringify(messages));
      }
    }
    cursor = page.list_complete ? undefined : page.cursor;
  } while (cursor);
}

function mediaIdFromUrl(url) {
  try {
    const parsed = new URL(url);
    if (parsed.pathname.startsWith("/media/")) {
      return parsed.pathname.replace(/^\/media\//, "");
    }
  } catch {
    return null;
  }
  return null;
}

// ─── Messages Web UI ───

function messagesHTML(token) {
  return `<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>SMS Messages | 323-642-3969</title>
<style>
  * { box-sizing: border-box; margin: 0; padding: 0; }
  body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; background: #0a0a0a; color: #e0e0e0; height: 100vh; display: flex; }
  .sidebar { width: 320px; border-right: 1px solid #222; display: flex; flex-direction: column; background: #111; }
  .sidebar-header { padding: 16px; border-bottom: 1px solid #222; }
  .sidebar-header h2 { font-size: 18px; color: #fff; }
  .sidebar-header .number { font-size: 12px; color: #888; margin-top: 2px; }
  .conv-list { flex: 1; overflow-y: auto; }
  .conv-item { padding: 12px 16px; border-bottom: 1px solid #1a1a1a; cursor: pointer; transition: background 0.15s; }
  .conv-item:hover, .conv-item.active { background: #1a1a1a; }
  .conv-item .conv-number { font-weight: 600; font-size: 14px; color: #fff; }
  .conv-item .conv-preview { font-size: 13px; color: #888; margin-top: 2px; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
  .conv-item .conv-time { font-size: 11px; color: #555; margin-top: 2px; }
  .conv-item .conv-media-badge { display: inline-block; font-size: 10px; background: #2a2a4a; color: #8888ff; padding: 1px 6px; border-radius: 8px; margin-left: 6px; }
  .new-conv-btn { margin: 12px 16px; padding: 10px; background: #1a5cff; color: #fff; border: none; border-radius: 8px; cursor: pointer; font-size: 14px; font-weight: 600; }
  .new-conv-btn:hover { background: #1449d6; }
  .chat-area { flex: 1; display: flex; flex-direction: column; }
  .chat-header { padding: 16px; border-bottom: 1px solid #222; background: #111; }
  .chat-header h3 { font-size: 16px; color: #fff; }
  .messages { flex: 1; overflow-y: auto; padding: 16px; display: flex; flex-direction: column; gap: 8px; }
  .msg { max-width: 70%; padding: 10px 14px; border-radius: 16px; font-size: 14px; line-height: 1.4; word-wrap: break-word; }
  .msg.inbound { align-self: flex-start; background: #222; color: #e0e0e0; border-bottom-left-radius: 4px; }
  .msg.outbound { align-self: flex-end; background: #1a5cff; color: #fff; border-bottom-right-radius: 4px; }
  .msg .msg-time { font-size: 10px; opacity: 0.6; margin-top: 4px; }
  .msg .msg-media { margin-top: 8px; }
  .msg .msg-media img { max-width: 100%; max-height: 300px; border-radius: 8px; cursor: pointer; }
  .msg .msg-media video { max-width: 100%; max-height: 300px; border-radius: 8px; }
  .msg .msg-media audio { width: 100%; margin-top: 4px; }
  .msg .msg-media .file-link { display: inline-block; padding: 6px 12px; background: rgba(255,255,255,0.1); border-radius: 6px; color: #8888ff; text-decoration: none; font-size: 13px; margin-top: 4px; }
  .msg .msg-media .file-link:hover { background: rgba(255,255,255,0.15); }
  .compose { padding: 12px 16px; border-top: 1px solid #222; background: #111; display: flex; gap: 8px; align-items: flex-end; }
  .compose textarea { flex: 1; background: #1a1a1a; border: 1px solid #333; border-radius: 12px; padding: 10px 14px; color: #e0e0e0; font-size: 14px; font-family: inherit; resize: none; min-height: 42px; max-height: 120px; }
  .compose textarea:focus { outline: none; border-color: #1a5cff; }
  .compose .media-input { width: 100%; background: #1a1a1a; border: 1px solid #333; border-radius: 8px; padding: 6px 10px; color: #e0e0e0; font-size: 12px; margin-bottom: 4px; }
  .compose .media-input:focus { outline: none; border-color: #1a5cff; }
  .compose button { background: #1a5cff; color: #fff; border: none; border-radius: 12px; padding: 10px 20px; cursor: pointer; font-size: 14px; font-weight: 600; white-space: nowrap; }
  .compose button:hover { background: #1449d6; }
  .compose button:disabled { opacity: 0.5; cursor: not-allowed; }
  .compose-col { flex: 1; display: flex; flex-direction: column; gap: 4px; }
  .empty-state { flex: 1; display: flex; align-items: center; justify-content: center; color: #555; font-size: 16px; }
  .loading { text-align: center; padding: 40px; color: #555; }
  @media (max-width: 700px) {
    .sidebar { width: 100%; position: absolute; z-index: 10; height: 100vh; }
    .sidebar.hidden { display: none; }
    .chat-area.hidden { display: none; }
    .back-btn { display: inline-block !important; }
  }
  .back-btn { display: none; cursor: pointer; background: none; border: none; color: #1a5cff; font-size: 14px; margin-right: 8px; }
</style>
</head>
<body>
<div class="sidebar" id="sidebar">
  <div class="sidebar-header">
    <h2>Messages</h2>
    <div class="number">323-642-3969</div>
  </div>
  <button class="new-conv-btn" onclick="newConversation()">+ New Message</button>
  <div class="conv-list" id="convList"><div class="loading">Loading...</div></div>
</div>
<div class="chat-area" id="chatArea">
  <div class="empty-state" id="emptyState">Select a conversation or start a new one</div>
  <div id="chatView" style="display:none; flex-direction:column; height:100%;">
    <div class="chat-header">
      <button class="back-btn" onclick="showSidebar()">&#8592; Back</button>
      <h3 id="chatTitle"></h3>
    </div>
    <div class="messages" id="messageList"></div>
    <div class="compose">
      <div class="compose-col">
        <textarea id="msgBody" placeholder="Type a message..." rows="1" onkeydown="if(event.key==='Enter'&&!event.shiftKey){event.preventDefault();sendMsg();}"></textarea>
        <input type="text" class="media-input" id="mediaUrl" placeholder="Media URL (optional, for MMS)">
      </div>
      <button onclick="sendMsg()" id="sendBtn">Send</button>
    </div>
  </div>
</div>

<script>
const TOKEN = ${JSON.stringify(token)};
const BASE = window.location.origin;
let currentNumber = null;
let pollInterval = null;

async function api(path) {
  const sep = path.includes("?") ? "&" : "?";
  const res = await fetch(BASE + path + sep + "token=" + encodeURIComponent(TOKEN));
  return res.json();
}

async function loadConversations() {
  const data = await api("/api/messages");
  const list = document.getElementById("convList");
  if (!data.conversations || data.conversations.length === 0) {
    list.innerHTML = '<div style="padding:16px;color:#555;">No messages yet</div>';
    return;
  }
  list.innerHTML = data.conversations.map(c => {
    const d = new Date(c.lastTimestamp);
    const time = d.toLocaleDateString() + " " + d.toLocaleTimeString([], {hour:"2-digit",minute:"2-digit"});
    const mediaBadge = c.hasMedia ? '<span class="conv-media-badge">MMS</span>' : '';
    return '<div class="conv-item' + (c.number === currentNumber ? ' active' : '') + '" onclick="openConversation(\\''+c.number+'\\')"><div class="conv-number">' + esc(c.number) + mediaBadge + '</div><div class="conv-preview">' + esc(c.lastMessage || "(media)") + '</div><div class="conv-time">' + time + '</div></div>';
  }).join("");
}

async function openConversation(number) {
  currentNumber = number;
  document.getElementById("emptyState").style.display = "none";
  const cv = document.getElementById("chatView");
  cv.style.display = "flex";
  document.getElementById("chatTitle").textContent = number;
  document.getElementById("sidebar").classList.add("hidden");
  await loadMessages();
  if (pollInterval) clearInterval(pollInterval);
  pollInterval = setInterval(loadMessages, 5000);
}

async function loadMessages() {
  if (!currentNumber) return;
  const data = await api("/api/messages?number=" + encodeURIComponent(currentNumber));
  const list = document.getElementById("messageList");
  list.innerHTML = (data.messages || []).map(m => {
    const d = new Date(m.timestamp);
    const time = d.toLocaleTimeString([], {hour:"2-digit",minute:"2-digit"});
    let mediaHtml = "";
    if (m.media && m.media.length > 0) {
      mediaHtml = '<div class="msg-media">' + m.media.map(med => renderMedia(med)).join("") + '</div>';
    }
    return '<div class="msg ' + m.direction + '">' + (m.body ? esc(m.body) : '') + mediaHtml + '<div class="msg-time">' + time + '</div></div>';
  }).join("");
  list.scrollTop = list.scrollHeight;
}

function renderMedia(med) {
  const ct = (med.contentType || "").toLowerCase();
  const url = med.url;
  if (ct.startsWith("image/")) {
    return '<img src="' + esc(url) + '" onclick="window.open(this.src)" alt="MMS image">';
  } else if (ct.startsWith("video/")) {
    return '<video controls src="' + esc(url) + '"></video>';
  } else if (ct.startsWith("audio/")) {
    return '<audio controls src="' + esc(url) + '"></audio>';
  } else {
    const ext = ct.split("/").pop() || "file";
    return '<a class="file-link" href="' + esc(url) + '" target="_blank">&#128206; Download ' + esc(ext.toUpperCase()) + '</a>';
  }
}

async function sendMsg() {
  const body = document.getElementById("msgBody").value.trim();
  const mediaUrl = document.getElementById("mediaUrl").value.trim();
  if ((!body && !mediaUrl) || !currentNumber) return;
  const btn = document.getElementById("sendBtn");
  btn.disabled = true;
  try {
    const payload = { to: currentNumber, body };
    if (mediaUrl) payload.mediaUrl = mediaUrl;
    await fetch(BASE + "/send-sms?token=" + encodeURIComponent(TOKEN), {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(payload),
    });
    document.getElementById("msgBody").value = "";
    document.getElementById("mediaUrl").value = "";
    await loadMessages();
    loadConversations();
  } finally {
    btn.disabled = false;
  }
}

function newConversation() {
  const number = prompt("Enter phone number (e.g. +15551234567):");
  if (number) openConversation(number.trim());
}

function showSidebar() {
  document.getElementById("sidebar").classList.remove("hidden");
  if (pollInterval) clearInterval(pollInterval);
}

function esc(s) {
  if (!s) return "";
  return s.replace(/&/g,"&amp;").replace(/</g,"&lt;").replace(/>/g,"&gt;").replace(/"/g,"&quot;");
}

loadConversations();
setInterval(loadConversations, 10000);
</script>
</body>
</html>`;
}

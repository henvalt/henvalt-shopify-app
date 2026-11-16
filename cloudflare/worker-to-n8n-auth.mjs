const encoder = new TextEncoder();

function asBytes(value) {
  if (!(value instanceof Uint8Array)) {
    throw new TypeError("rawBody must be a Uint8Array");
  }
  return value;
}

function toBase64(bytes) {
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary);
}

function fromBase64(value) {
  const binary = atob(value);
  return Uint8Array.from(binary, (char) => char.charCodeAt(0));
}

function constantTimeEqual(left, right) {
  if (left.length !== right.length) return false;
  let difference = 0;
  for (let index = 0; index < left.length; index += 1) {
    difference |= left[index] ^ right[index];
  }
  return difference === 0;
}

function validateMetadata(timestamp, requestId) {
  if (!/^\\d{10}$/.test(String(timestamp))) {
    throw new TypeError("timestamp must be Unix seconds");
  }
  if (!/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(String(requestId))) {
    throw new TypeError("requestId must be a UUIDv4");
  }
}

async function signatureFor(rawBody, secret, timestamp, requestId) {
  const key = await crypto.subtle.importKey(
    "raw",
    encoder.encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign", "verify"],
  );
  const prefix = encoder.encode(String(timestamp) + "." + requestId + ".");
  const message = new Uint8Array(prefix.length + rawBody.length);
  message.set(prefix, 0);
  message.set(rawBody, prefix.length);
  const signature = await crypto.subtle.sign("HMAC", key, message);
  return new Uint8Array(signature);
}

export async function buildInternalAuthHeaders(rawBody, secret, metadata) {
  const bytes = asBytes(rawBody);
  if (typeof secret !== "string" || secret.length < 32) {
    throw new TypeError("internal signing secret must contain at least 32 characters");
  }
  const timestamp = String(metadata?.timestamp ?? "");
  const requestId = String(metadata?.requestId ?? "");
  validateMetadata(timestamp, requestId);
  const signature = await signatureFor(bytes, secret, timestamp, requestId);
  return {
    "x-henvalt-internal-timestamp": timestamp,
    "x-henvalt-internal-request-id": requestId,
    "x-henvalt-internal-signature": toBase64(signature),
  };
}

export async function verifyInternalAuth(rawBody, secret, headers, options = {}) {
  try {
    const bytes = asBytes(rawBody);
    if (typeof secret !== "string" || secret.length < 32) return false;
    const timestamp = String(headers?.timestamp ?? "");
    const requestId = String(headers?.requestId ?? "");
    const supplied = String(headers?.signature ?? "");
    validateMetadata(timestamp, requestId);
    if (!/^[A-Za-z0-9+/]{43}=$/.test(supplied)) return false;
    const now = Number.isInteger(options.now) ? options.now : Math.floor(Date.now() / 1000);
    const tolerance = Number.isInteger(options.toleranceSeconds) ? options.toleranceSeconds : 300;
    if (Math.abs(now - Number(timestamp)) > tolerance) return false;
    const expected = await signatureFor(bytes, secret, timestamp, requestId);
    return constantTimeEqual(expected, fromBase64(supplied));
  } catch {
    return false;
  }
}

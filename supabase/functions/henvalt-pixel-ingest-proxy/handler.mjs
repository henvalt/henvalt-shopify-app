const STAGING_PROJECT_REF = "xidhtmrfvsgfmyltjuja";
const MAX_BODY_BYTES = 16_000;
const EVENT_TYPES = new Set([
  "page_viewed",
  "product_viewed",
  "product_added_to_cart",
  "product_removed_from_cart",
  "checkout_started",
]);

const json = (status, body) => Response.json(body, {
  status,
  headers: { "cache-control": "no-store" },
});

function configured(env) {
  try {
    const url = new URL(env.SUPABASE_URL);
    return env.HENVALT_STAGE_NO_SEND === "true" &&
      url.protocol === "https:" &&
      url.hostname === `${STAGING_PROJECT_REF}.supabase.co` &&
      url.pathname === "/" && !url.username && !url.password && !url.search && !url.hash &&
      typeof env.SUPABASE_SERVICE_ROLE_KEY === "string" &&
      env.SUPABASE_SERVICE_ROLE_KEY.length > 40;
  } catch {
    return false;
  }
}

async function readLimited(request, limit) {
  const reader = request.body?.getReader();
  if (!reader) return new Uint8Array();
  const chunks = [];
  let size = 0;
  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      size += value.byteLength;
      if (size > limit) {
        await reader.cancel();
        return null;
      }
      chunks.push(value);
    }
  } finally {
    reader.releaseLock();
  }
  const bytes = new Uint8Array(size);
  let offset = 0;
  for (const chunk of chunks) {
    bytes.set(chunk, offset);
    offset += chunk.byteLength;
  }
  return bytes;
}

async function sha256Hex(value) {
  const digest = new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(value)));
  return Array.from(digest, (byte) => byte.toString(16).padStart(2, "0")).join("");
}

function safeEqual(a, b) {
  if (a.length !== b.length) return false;
  let difference = 0;
  for (let i = 0; i < a.length; i++) difference |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return difference === 0;
}

async function db(env, path, init = {}, fetchImpl = fetch) {
  try {
    return await fetchImpl(env.SUPABASE_URL + path, {
      ...init,
      signal: init.signal ?? AbortSignal.timeout(1800),
      headers: {
        apikey: env.SUPABASE_SERVICE_ROLE_KEY,
        authorization: "Bearer " + env.SUPABASE_SERVICE_ROLE_KEY,
        "content-type": "application/json",
        "accept-profile": "henvalt",
        "content-profile": "henvalt",
        ...(init.headers ?? {}),
      },
    });
  } catch {
    return null;
  }
}

export async function handlePixelIngestProxy(request, env, fetchImpl = fetch) {
  const url = new URL(request.url);
  if (request.method !== "POST" || url.pathname !== "/") return json(404, { error: "not_found" });
  if (!configured(env)) return json(503, { error: "staging_pixel_proxy_configuration_missing" });
  const contentType = (request.headers.get("content-type") ?? "").split(";")[0].trim().toLowerCase();
  if (contentType !== "application/json") return json(415, { error: "application_json_required" });

  const declaredLength = Number(request.headers.get("content-length") || "0");
  if (Number.isFinite(declaredLength) && declaredLength > MAX_BODY_BYTES) return json(413, { error: "payload_too_large" });
  const raw = await readLimited(request, MAX_BODY_BYTES);
  if (raw === null) return json(413, { error: "payload_too_large" });

  let input;
  try {
    input = JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(raw));
  } catch {
    return json(400, { error: "invalid_json" });
  }
  if (!input || typeof input !== "object" || Array.isArray(input)) return json(400, { error: "invalid_request" });

  const keyDigest = typeof input.p_key_digest === "string" ? input.p_key_digest : "";
  const origin = typeof input.p_origin === "string" ? input.p_origin : "";
  const collectorSecret = typeof input.p_collector_secret === "string" ? input.p_collector_secret : "";
  const payload = input.p_payload;
  if (!/^[a-f0-9]{64}$/.test(keyDigest) || collectorSecret.length < 32 ||
      !payload || typeof payload !== "object" || Array.isArray(payload)) {
    return json(400, { error: "invalid_request" });
  }
  let parsedOrigin;
  try {
    parsedOrigin = new URL(origin);
  } catch {
    return json(400, { error: "invalid_origin" });
  }
  if (parsedOrigin.protocol !== "https:" || parsedOrigin.origin !== origin ||
      parsedOrigin.username || parsedOrigin.password || parsedOrigin.search || parsedOrigin.hash) {
    return json(400, { error: "invalid_origin" });
  }
  if (payload.analytics_consent !== true) return json(403, { error: "analytics_consent_required" });
  if (payload.schema_version !== 1 || !EVENT_TYPES.has(payload.event_type) ||
      typeof payload.event_id !== "string" || payload.event_id.length < 1 || payload.event_id.length > 160 ||
      typeof payload.client_id !== "string" || payload.client_id.length < 1 || payload.client_id.length > 160) {
    return json(400, { error: "invalid_event" });
  }

  const expectedDigest = await sha256Hex(collectorSecret);
  const authResponse = await db(
    env,
    "/rest/v1/pixel_collector_auth?select=secret_digest&singleton=eq.true&limit=1",
    {},
    fetchImpl,
  );
  if (!authResponse?.ok) return json(503, { error: "collector_auth_unavailable" });
  const authRows = await authResponse.json().catch(() => null);
  const storedValue = Array.isArray(authRows) && authRows.length === 1
    ? String(authRows[0]?.secret_digest ?? "")
    : "";
  const storedDigest = storedValue.startsWith("\\x") ? storedValue.slice(2) : storedValue;
  if (!/^[a-f0-9]{64}$/.test(storedDigest) || !safeEqual(expectedDigest, storedDigest)) {
    return json(401, { error: "collector_authentication_failed" });
  }

  const ingestResponse = await db(
    env,
    "/rest/v1/rpc/ingest_pixel_event",
    {
      method: "POST",
      body: JSON.stringify({
        p_key_digest: keyDigest,
        p_origin: origin,
        p_payload: payload,
      }),
    },
    fetchImpl,
  );
  if (!ingestResponse?.ok) return json(503, { error: "pixel_ingest_unavailable" });
  const result = await ingestResponse.json().catch(() => null);
  if (result?.error === "rate_limited") return json(429, { accepted: false, error: "rate_limited" });
  if (result?.error === "analytics_consent_required") return json(403, { accepted: false, error: "analytics_consent_required" });
  if (result?.accepted !== true) return json(401, { accepted: false, error: "event_rejected" });
  return json(202, { accepted: true, duplicate: result.duplicate === true });
}

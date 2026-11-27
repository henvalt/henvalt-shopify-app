const STAGING_PROJECT_REF = "xidhtmrfvsgfmyltjuja";
const MAX_BODY_BYTES = 1_000_000;
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const ACTIVE_JOB_STATES = new Set(["QUEUED", "CLAIMED", "RUNNING", "RETRY_WAIT"]);

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
      env.SUPABASE_SERVICE_ROLE_KEY.length > 40 &&
      typeof env.HENVALT_INGRESS_SHARED_SECRET === "string" &&
      env.HENVALT_INGRESS_SHARED_SECRET.length >= 32 &&
      typeof env.SHOPIFY_API_SECRET === "string" &&
      env.SHOPIFY_API_SECRET.length >= 16;
  } catch {
    return false;
  }
}

function constantTimeEqual(a, b) {
  const x = new TextEncoder().encode(a);
  const y = new TextEncoder().encode(b);
  if (x.length !== y.length) return false;
  let diff = 0;
  for (let i = 0; i < x.length; i++) diff |= x[i] ^ y[i];
  return diff === 0;
}

async function verifyShopifyHmac(raw, supplied, secret) {
  if (!/^[A-Za-z0-9+/]{43}=$/.test(supplied)) return false;
  const key = await crypto.subtle.importKey(
    "raw", new TextEncoder().encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"],
  );
  const digest = new Uint8Array(await crypto.subtle.sign("HMAC", key, raw));
  let binary = "";
  for (const byte of digest) binary += String.fromCharCode(byte);
  return constantTimeEqual(btoa(binary), supplied);
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
    offset += chunk.length;
  }
  return bytes;
}

function base64(bytes) {
  let binary = "";
  const chunkSize = 0x8000;
  for (let i = 0; i < bytes.length; i += chunkSize) {
    binary += String.fromCharCode(...bytes.subarray(i, i + chunkSize));
  }
  return btoa(binary);
}

export async function handleShopifyWebhookIngress(request, env, fetchImpl = fetch) {
  const url = new URL(request.url);
  if (request.method === "OPTIONS") return new Response(null, { status: 204 });
  if (request.method !== "POST" || url.pathname !== "/") return json(404, { error: "not_found" });
  if (!configured(env)) return json(503, { error: "staging_ingress_configuration_missing" });

  const supplied = request.headers.get("authorization")?.replace(/^Bearer\\s+/i, "") ?? "";
  if (!constantTimeEqual(supplied, env.HENVALT_INGRESS_SHARED_SECRET)) {
    return json(401, { error: "unauthorized_ingress_worker" });
  }

  const shop = (request.headers.get("x-shopify-shop-domain") || "").toLowerCase();
  const topic = (request.headers.get("x-shopify-topic") || "").toLowerCase();
  const hmac = request.headers.get("x-shopify-hmac-sha256") || "";
  const deliveryId = request.headers.get("x-shopify-webhook-id") || "";
  if (!/^[a-z0-9][a-z0-9-]*\\.myshopify\\.com$/.test(shop) ||
      !/^[a-z0-9_./-]{2,100}$/.test(topic) || !hmac || !deliveryId || deliveryId.length > 200) {
    return json(400, { error: "invalid_webhook_headers" });
  }

  const declaredLength = Number(request.headers.get("content-length") || "0");
  if (Number.isFinite(declaredLength) && declaredLength > MAX_BODY_BYTES) return json(413, { error: "body_too_large" });
  const raw = await readLimited(request, MAX_BODY_BYTES);
  if (raw === null) return json(413, { error: "body_too_large" });

  if (!await verifyShopifyHmac(raw, hmac, env.SHOPIFY_API_SECRET)) {
    return json(401, { error: "invalid_hmac" });
  }

  let payload;
  try {
    payload = JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(raw));
  } catch {
    return json(422, { error: "malformed_event" });
  }
  if (!payload || typeof payload !== "object" || Array.isArray(payload)) return json(422, { error: "malformed_event" });

  const metadata = { ingress_hmac_verified: true, hmac_verifier: "shopify_edge_function" };
  for (const [header, key] of [
    ["x-shopify-event-id", "shopify_event_id"],
    ["x-shopify-api-version", "shopify_api_version"],
    ["x-shopify-triggered-at", "shopify_triggered_at"],
  ]) {
    const value = request.headers.get(header);
    if (value) metadata[key] = value.slice(0, 200);
  }

  let upstream;
  try {
    upstream = await fetchImpl(`${env.SUPABASE_URL}/rest/v1/rpc/receive_shopify_webhook_edge_verified_v1`, {
      method: "POST",
      headers: {
        apikey: env.SUPABASE_SERVICE_ROLE_KEY,
        authorization: `Bearer ${env.SUPABASE_SERVICE_ROLE_KEY}`,
        "content-type": "application/json",
        "accept-profile": "henvalt",
        "content-profile": "henvalt",
      },
      body: JSON.stringify({
        p_shop_domain: shop,
        p_topic: topic,
        p_delivery_id: deliveryId,
        p_raw_body_base64: base64(raw),
        p_payload: payload,
        p_metadata: metadata,
      }),
      redirect: "manual",
      signal: AbortSignal.timeout(5000),
    });
  } catch {
    return json(503, { error: "durable_ingest_unavailable" });
  }
  if (!upstream.ok) return json(503, { error: "durable_ingest_unavailable" });

  let rows;
  try { rows = await upstream.json(); } catch { return json(503, { error: "durable_ingest_unavailable" }); }
  const row = Array.isArray(rows) ? rows[0] : null;
  if (!row || !Number.isInteger(row.http_status)) return json(503, { error: "durable_ingest_ack_invalid" });
  if (row.http_status === 404) return json(404, { error: "unknown_tenant" });
  if (row.http_status === 422) return json(422, { error: "malformed_event" });
  if (row.http_status !== 200 || !UUID_RE.test(String(row.webhook_id || ""))) {
    return json(503, { error: "durable_ingest_not_confirmed" });
  }
  if (row.result_status === "duplicate") {
    return json(200, {
      status: "duplicate", webhook_id: row.webhook_id,
      processing_status: "PROCESSED", correlation_id: row.correlation_id,
    });
  }
  const jobId = String(row.replay_job_id || "");
  const jobStatus = String(row.replay_job_status || "").toUpperCase();
  if (!["accepted", "replay_accepted"].includes(String(row.result_status)) ||
      !UUID_RE.test(jobId) || !ACTIVE_JOB_STATES.has(jobStatus)) {
    return json(503, { error: "durable_replay_job_not_confirmed" });
  }
  return json(200, {
    status: row.result_status,
    webhook_id: row.webhook_id,
    replay_job_id: jobId,
    replay_job_status: jobStatus,
    processing_status: row.processing_status,
    correlation_id: row.correlation_id,
  });
}

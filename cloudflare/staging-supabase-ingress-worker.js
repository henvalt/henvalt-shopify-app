const STAGING_PROJECT_REF = "xidhtmrfvsgfmyltjuja";
const MAX_BODY_BYTES = 1_000_000;
export const STAGING_SUPABASE_INGRESS_TIMEOUT_MS = 4_300;
const UPSTREAM_PATH = "/functions/v1/henvalt-shopify-webhook-ingress";
const HEADER_ALLOWLIST = [
  "content-type",
  "x-shopify-hmac-sha256",
  "x-shopify-shop-domain",
  "x-shopify-topic",
  "x-shopify-webhook-id",
  "x-shopify-event-id",
  "x-shopify-api-version",
  "x-shopify-triggered-at",
];
const SHOP_RE = /^[a-z0-9][a-z0-9-]*[.]myshopify[.]com$/;
const TOPIC_RE = /^[a-z0-9_./-]{2,100}$/;
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const ACTIVE_JOB_STATES = new Set(["QUEUED", "CLAIMED", "RUNNING", "RETRY_WAIT"]);

function configured(env) {
  try {
    const url = new URL(env.SUPABASE_URL);
    return env.HENVALT_STAGE_NO_SEND === "true" &&
      url.protocol === "https:" &&
      url.hostname === `${STAGING_PROJECT_REF}.supabase.co` &&
      url.pathname === "/" && !url.username && !url.password && !url.search && !url.hash;
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

const json = (status, body) => Response.json(body, {
  status,
  headers: { "cache-control": "no-store" },
});

export async function handleStagingSupabaseIngress(request, env, fetchImpl = fetch) {
  const url = new URL(request.url);
  const isConfigured = configured(env);
  if (request.method === "GET" && (url.pathname === "/" || url.pathname === "/health")) {
    return json(200, {
      service: "henvalt-shopify-ingress-staging-no-send",
      configured: isConfigured,
      no_send: env.HENVALT_STAGE_NO_SEND === "true",
      hmac_verification: "supabase_edge_function",
      runtime: "supabase-edge-function-durable-ingest-rpc",
    });
  }
  if (request.method === "OPTIONS") return new Response(null, { status: 204 });
  if (request.method !== "POST" || url.pathname !== "/shopify/webhooks") {
    return json(404, { error: "not_found" });
  }
  if (!isConfigured) return json(503, { error: "staging_ingress_configuration_missing" });

  const shop = (request.headers.get("x-shopify-shop-domain") || "").toLowerCase();
  const topic = (request.headers.get("x-shopify-topic") || "").toLowerCase();
  const hmac = request.headers.get("x-shopify-hmac-sha256") || "";
  const deliveryId = request.headers.get("x-shopify-webhook-id") || "";
  if (!SHOP_RE.test(shop) || !TOPIC_RE.test(topic) || !hmac || !deliveryId || deliveryId.length > 200) {
    return json(400, { error: "invalid_webhook_headers" });
  }

  const declaredLength = Number(request.headers.get("content-length") || "0");
  if (Number.isFinite(declaredLength) && declaredLength > MAX_BODY_BYTES) {
    return json(413, { error: "body_too_large" });
  }
  const raw = await readLimited(request, MAX_BODY_BYTES);
  if (raw === null) return json(413, { error: "body_too_large" });

  // Preserve the exact raw bytes: Supabase verifies Shopify's HMAC before parsing.
  // The Worker never accepts or forwards an internal bearer/shared-secret header.
  const headers = new Headers();
  for (const name of HEADER_ALLOWLIST) {
    const value = request.headers.get(name);
    if (value !== null) headers.set(name, value);
  }

  let upstream;
  try {
    upstream = await fetchImpl(`https://${STAGING_PROJECT_REF}.supabase.co${UPSTREAM_PATH}`, {
      method: "POST",
      headers,
      body: raw,
      redirect: "manual",
      signal: AbortSignal.timeout(STAGING_SUPABASE_INGRESS_TIMEOUT_MS),
    });
  } catch {
    return json(503, { error: "durable_ingest_unavailable" });
  }

  let body;
  try { body = await upstream.json(); } catch { body = null; }
  if (upstream.status !== 200) {
    const error = body && typeof body === "object" ? body.error : null;
    if (upstream.status === 401 && error === "invalid_hmac") return json(401, { error: "invalid_hmac" });
    if (upstream.status === 404 && error === "unknown_tenant") return json(404, { error: "unknown_tenant" });
    if (upstream.status === 422 && error === "malformed_event") return json(422, { error: "malformed_event" });
    return json(503, { error: "durable_ingest_unavailable" });
  }

  if (!body || typeof body !== "object" || !UUID_RE.test(String(body.webhook_id || ""))) {
    return json(503, { error: "durable_ingest_ack_invalid" });
  }
  if (body.status === "duplicate" && body.processing_status === "PROCESSED") {
    return json(200, {
      status: "duplicate",
      webhook_id: body.webhook_id,
      processing_status: "PROCESSED",
      correlation_id: body.correlation_id,
    });
  }
  const jobId = String(body.replay_job_id || "");
  const jobStatus = String(body.replay_job_status || "").toUpperCase();
  if (!["accepted", "replay_accepted"].includes(String(body.status)) ||
      !UUID_RE.test(jobId) || !ACTIVE_JOB_STATES.has(jobStatus)) {
    return json(503, { error: "durable_replay_job_not_confirmed" });
  }
  return json(200, {
    status: body.status,
    webhook_id: body.webhook_id,
    replay_job_id: jobId,
    replay_job_status: jobStatus,
    processing_status: body.processing_status,
    correlation_id: body.correlation_id,
  });
}

export default {
  fetch(request, env) {
    return handleStagingSupabaseIngress(request, env);
  },
};

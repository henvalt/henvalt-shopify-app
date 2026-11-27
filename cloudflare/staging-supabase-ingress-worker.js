const STAGING_PROJECT_REF = "xidhtmrfvsgfmyltjuja";
const MAX_BODY_BYTES = 1_000_000;
export const STAGING_SUPABASE_INGRESS_TIMEOUT_MS = 3500;

function configured(env) {
  try {
    const url = new URL(env.SUPABASE_URL);
    return env.HENVALT_STAGE_NO_SEND === "true" &&
      url.protocol === "https:" &&
      url.hostname === `${STAGING_PROJECT_REF}.supabase.co` &&
      url.pathname === "/" && !url.username && !url.password && !url.search && !url.hash &&
      typeof env.HENVALT_INGRESS_SHARED_SECRET === "string" &&
      env.HENVALT_INGRESS_SHARED_SECRET.length >= 32;
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
      if (size > limit) { await reader.cancel(); return null; }
      chunks.push(value);
    }
  } finally { reader.releaseLock(); }
  const bytes = new Uint8Array(size);
  let offset = 0;
  for (const chunk of chunks) { bytes.set(chunk, offset); offset += chunk.byteLength; }
  return bytes;
}

export async function handleStagingSupabaseIngress(request, env, fetchImpl = fetch) {
  const url = new URL(request.url);
  const isConfigured = configured(env);
  if (request.method === "GET" && (url.pathname === "/" || url.pathname === "/health")) {
    return Response.json({
      service: "henvalt-shopify-ingress-staging-no-send",
      configured: isConfigured,
      no_send: env.HENVALT_STAGE_NO_SEND === "true",
      runtime: "supabase-edge-function-durable-ingest-rpc",
    }, { headers: { "cache-control": "no-store" } });
  }
  if (request.method === "OPTIONS") return new Response(null, { status: 204 });
  if (request.method !== "POST" || url.pathname !== "/shopify/webhooks") {
    return Response.json({ error: "not_found" }, { status: 404 });
  }
  if (!isConfigured) return Response.json({ error: "staging_ingress_configuration_missing" }, { status: 503 });

  const shop = (request.headers.get("x-shopify-shop-domain") || "").toLowerCase();
  const topic = (request.headers.get("x-shopify-topic") || "").toLowerCase();
  const hmac = request.headers.get("x-shopify-hmac-sha256") || "";
  const deliveryId = request.headers.get("x-shopify-webhook-id") || "";
  if (!/^[a-z0-9][a-z0-9-]*\.myshopify\.com$/.test(shop) ||
      !/^[a-z0-9_./-]{2,100}$/.test(topic) || !hmac || !deliveryId || deliveryId.length > 200) {
    return Response.json({ error: "invalid_webhook_headers" }, { status: 400 });
  }
  const declaredLength = Number(request.headers.get("content-length") || "0");
  if (Number.isFinite(declaredLength) && declaredLength > MAX_BODY_BYTES) {
    return Response.json({ error: "body_too_large" }, { status: 413 });
  }
  const raw = await readLimited(request, MAX_BODY_BYTES);
  if (raw === null) return Response.json({ error: "body_too_large" }, { status: 413 });
  let payload;
  try { payload = JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(raw)); }
  catch { return Response.json({ error: "malformed_event" }, { status: 422 }); }
  if (!payload || typeof payload !== "object" || Array.isArray(payload)) {
    return Response.json({ error: "malformed_event" }, { status: 422 });
  }

  const headers = new Headers({
    authorization: `Bearer ${env.HENVALT_INGRESS_SHARED_SECRET}`,
    "content-type": request.headers.get("content-type") || "application/json",
  });
  for (const name of [
    "x-shopify-hmac-sha256", "x-shopify-shop-domain", "x-shopify-topic",
    "x-shopify-webhook-id", "x-shopify-event-id", "x-shopify-api-version", "x-shopify-triggered-at",
  ]) {
    const value = request.headers.get(name);
    if (value !== null) headers.set(name, value);
  }
  let upstream;
  try {
    upstream = await fetchImpl(`${env.SUPABASE_URL}/functions/v1/henvalt-shopify-webhook-ingress`, {
      method: "POST", headers, body: raw, redirect: "manual",
      signal: AbortSignal.timeout(STAGING_SUPABASE_INGRESS_TIMEOUT_MS),
    });
  } catch {
    return Response.json({ error: "durable_ingest_unavailable" }, { status: 503 });
  }
  let upstreamBody;
  try { upstreamBody = await upstream.json(); } catch { upstreamBody = null; }
  if (upstream.status !== 200) {
    const upstreamError = upstreamBody && typeof upstreamBody === "object"
      ? upstreamBody.error
      : null;
    // Preserve only the three intentional event-rejection outcomes. An
    // internal worker-auth/configuration failure must remain retryable (503),
    // not be misreported to Shopify as a bad customer event.
    if (upstream.status === 401 && upstreamError === "invalid_hmac") {
      return Response.json({ error: "invalid_hmac" }, { status: 401 });
    }
    if (upstream.status === 404 && upstreamError === "unknown_tenant") {
      return Response.json({ error: "unknown_tenant" }, { status: 404 });
    }
    if (upstream.status === 422 && upstreamError === "malformed_event") {
      return Response.json({ error: "malformed_event" }, { status: 422 });
    }
    return Response.json({ error: "durable_ingest_unavailable" }, { status: 503 });
  }
  const acknowledgement = upstreamBody;

  const uuid = (v) => typeof v === "string" && /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(v);
  if (!uuid(acknowledgement?.webhook_id)) {
    return Response.json({ error: "durable_ingest_ack_invalid" }, { status: 503 });
  }
  if (acknowledgement.status === "duplicate" && acknowledgement.processing_status === "PROCESSED") {
    return Response.json(acknowledgement, { status: 200, headers: { "cache-control": "no-store" } });
  }
  if (!["accepted", "replay_accepted"].includes(acknowledgement.status) ||
      !uuid(acknowledgement.replay_job_id) ||
      !["QUEUED", "CLAIMED", "RUNNING", "RETRY_WAIT"].includes(String(acknowledgement.replay_job_status).toUpperCase())) {
    return Response.json({ error: "durable_replay_job_not_confirmed" }, { status: 503 });
  }
  return Response.json(acknowledgement, { status: 200, headers: { "cache-control": "no-store" } });
}

export default { fetch(request, env) { return handleStagingSupabaseIngress(request, env); } };

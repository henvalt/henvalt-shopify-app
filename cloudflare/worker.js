export const SHOPIFY_WEBHOOK_UPSTREAM_TIMEOUT_MS = 3500;

export async function handleRequest(request, env, fetchImpl = fetch) {
  const url = new URL(request.url);
  if (request.method === "GET" && (url.pathname === "/" || url.pathname === "/health")) {
    return Response.json({ service: "henvalt-clean-ingress-v1", configured: Boolean(env.SHOPIFY_API_SECRET && env.N8N_INGEST_URL) }, { headers: { "cache-control": "no-store" } });
  }
  if (request.method === "OPTIONS") return new Response(null, { status: 204 });
  if (request.method !== "POST" || url.pathname !== "/shopify/webhooks") return Response.json({ error: "not_found" }, { status: 404 });

  // Fail closed before reading or forwarding a delivery when ingress is misconfigured.
  let upstreamUrl;
  try {
    const parsed = new URL(env.N8N_INGEST_URL);
    if (parsed.protocol === "https:" && !parsed.username && !parsed.password) upstreamUrl = parsed.toString();
  } catch {
    // Invalid or absent upstream configuration is handled by the fail-closed response below.
  }
  if (typeof env.SHOPIFY_API_SECRET !== "string" || !env.SHOPIFY_API_SECRET || !upstreamUrl) {
    return Response.json({ error: "ingress_configuration_missing" }, { status: 503 });
  }

  const shop = (request.headers.get("x-shopify-shop-domain") || "").toLowerCase();
  const topic = (request.headers.get("x-shopify-topic") || "").toLowerCase();
  const hmac = request.headers.get("x-shopify-hmac-sha256") || "";
  const webhookId = request.headers.get("x-shopify-webhook-id") || "";
  if (!/^[a-z0-9][a-z0-9-]*\.myshopify\.com$/.test(shop) || !topic || !hmac || !webhookId) return Response.json({ error: "invalid_webhook_headers" }, { status: 400 });

  const contentLength = Number(request.headers.get("content-length") || "0");
  if (Number.isFinite(contentLength) && contentLength > 1_000_000) return Response.json({ error: "body_too_large" }, { status: 413 });
  const rawBytes = await readBodyBytesLimited(request, 1_000_000);
  if (rawBytes === null) return Response.json({ error: "body_too_large" }, { status: 413 });

  const key = await crypto.subtle.importKey("raw", new TextEncoder().encode(env.SHOPIFY_API_SECRET), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const sig = new Uint8Array(await crypto.subtle.sign("HMAC", key, rawBytes));
  const expected = btoa(String.fromCharCode(...sig));
  if (!constantTimeEqual(expected, hmac)) return Response.json({ error: "invalid_hmac" }, { status: 401 });

  // Forward only Shopify's signed delivery envelope. Never relay caller-controlled
  // Authorization, Cookie, Origin, Host, proxy, or arbitrary custom headers to n8n.
  const forwardedHeaders = new Headers();
  for (const name of [
    "content-type",
    "x-shopify-hmac-sha256",
    "x-shopify-shop-domain",
    "x-shopify-topic",
    "x-shopify-webhook-id",
    "x-shopify-event-id",
    "x-shopify-api-version",
    "x-shopify-triggered-at",
  ]) {
    const value = request.headers.get(name);
    if (value !== null) forwardedHeaders.set(name, value);
  }

  let upstream;
  try {
    upstream = await fetchImpl(upstreamUrl, {
      method: "POST",
      headers: forwardedHeaders,
      body: rawBytes,
      redirect: "manual",
      signal: AbortSignal.timeout(SHOPIFY_WEBHOOK_UPSTREAM_TIMEOUT_MS),
    });
  } catch {
    return Response.json({ error: "ingest_unavailable" }, { status: 503 });
  }
  // Only the exact durable-ingest acknowledgement contract may stop Shopify retries.
  // A generic 2xx, empty 204, malformed JSON, or proxy-generated success is not proof
  // that the webhook row and replay job were committed.
  if (upstream.status !== 200) {
    return Response.json({ error: "ingest_unavailable" }, { status: 503 });
  }
  let acknowledgement;
  try {
    acknowledgement = await upstream.json();
  } catch {
    return Response.json({ error: "ingest_unavailable" }, { status: 503 });
  }
  const isUuid = (value) => typeof value === "string" &&
    /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(value);
  const status = acknowledgement && acknowledgement.status;
  const durableWebhook = isUuid(acknowledgement?.webhook_id);
  const terminalDuplicate = status === "duplicate" && durableWebhook;
  const queuedAcceptance = ["accepted", "replay_accepted", "already_processing"].includes(status) &&
    durableWebhook &&
    isUuid(acknowledgement?.replay_job_id) &&
    ["QUEUED", "CLAIMED", "RUNNING", "RETRY_WAIT"].includes(String(acknowledgement?.replay_job_status || "").toUpperCase());
  if (!terminalDuplicate && !queuedAcceptance) {
    return Response.json({ error: "ingest_unavailable" }, { status: 503 });
  }
  return Response.json(acknowledgement, { status: 200, headers: { "cache-control": "no-store" } });
}

export default {
  fetch(request, env) {
    return handleRequest(request, env);
  }
};

async function readBodyBytesLimited(request, maxBytes) {
  const reader = request.body?.getReader();
  if (!reader) return new Uint8Array();
  const chunks = [];
  let total = 0;
  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      total += value.byteLength;
      if (total > maxBytes) {
        await reader.cancel();
        return null;
      }
      chunks.push(value);
    }
  } finally {
    reader.releaseLock();
  }
  const body = new Uint8Array(total);
  let offset = 0;
  for (const chunk of chunks) {
    body.set(chunk, offset);
    offset += chunk.byteLength;
  }
  return body;
}

function constantTimeEqual(a, b) {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}

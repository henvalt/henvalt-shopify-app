const MAX_BODY_BYTES = 1_000_000;
const SHOP_DOMAIN_RE = /^[a-z0-9][a-z0-9-]*\.myshopify\.com$/;
const encoder = new TextEncoder();

function json(data, status = 200) {
  return new Response(JSON.stringify(data), {
    status,
    headers: {
      "content-type": "application/json; charset=utf-8",
      "cache-control": "no-store",
    },
  });
}

async function readBoundedBody(request) {
  if (!request.body) return { error: "empty_body" };
  const reader = request.body.getReader();
  const chunks = [];
  let totalBytes = 0;
  try {
    while (true) {
      const part = await reader.read();
      if (part.done) break;
      totalBytes += part.value.byteLength;
      if (totalBytes > MAX_BODY_BYTES) {
        await reader.cancel();
        return { error: "body_too_large" };
      }
      chunks.push(part.value);
    }
  } catch {
    return { error: "body_unreadable" };
  } finally {
    reader.releaseLock();
  }
  if (totalBytes === 0) return { error: "empty_body" };
  const bytes = new Uint8Array(totalBytes);
  let offset = 0;
  for (const chunk of chunks) {
    bytes.set(chunk, offset);
    offset += chunk.byteLength;
  }
  return { bytes };
}

function constantTimeEqual(left, right) {
  if (left.length !== right.length) return false;
  let difference = 0;
  for (let index = 0; index < left.length; index++) {
    difference |= left.charCodeAt(index) ^ right.charCodeAt(index);
  }
  return difference === 0;
}

export async function verifyShopifyHmac(rawBody, received, secret) {
  if (!secret || !received) return false;
  const key = await crypto.subtle.importKey(
    "raw",
    encoder.encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const signature = await crypto.subtle.sign("HMAC", key, rawBody);
  let binary = "";
  for (const byte of new Uint8Array(signature)) binary += String.fromCharCode(byte);
  return constantTimeEqual(btoa(binary), received);
}

export function createHandler(options = {}) {
  const fetchImpl = options.fetchImpl || fetch;

  return async function handleRequest(request, env) {
    const url = new URL(request.url);

    if (request.method === "GET" && (url.pathname === "/" || url.pathname === "/health")) {
      const required = ["SHOPIFY_API_SECRET", "N8N_INGEST_URL"];
      const missing = required.filter((name) => !env || !env[name]);
      return json({
        service: "HENVALT clean-start ingress",
        status: missing.length ? "needs_configuration" : "ready",
        configured: required.filter((name) => !!(env && env[name])),
        missing,
        endpoints: { health: "GET /health", shopifyWebhook: "POST /shopify/webhooks" },
      }, missing.length ? 503 : 200);
    }

    if (request.method === "OPTIONS") return new Response(null, { status: 204 });
    if (request.method !== "POST" || url.pathname !== "/shopify/webhooks") {
      return json({ ok: false, error: "not_found" }, 404);
    }

    const missing = ["SHOPIFY_API_SECRET", "N8N_INGEST_URL"].filter((name) => !env || !env[name]);
    if (missing.length) return json({ ok: false, error: "ingress_not_configured", missing }, 503);

    const shop = (request.headers.get("X-Shopify-Shop-Domain") || "").toLowerCase();
    const topic = request.headers.get("X-Shopify-Topic") || "";
    const receivedHmac = request.headers.get("X-Shopify-Hmac-Sha256") || "";
    const webhookId = request.headers.get("X-Shopify-Webhook-Id") ||
      request.headers.get("X-Shopify-Event-Id") || "";

    if (!SHOP_DOMAIN_RE.test(shop) || !topic || topic.length > 128 ||
        !receivedHmac || !webhookId || webhookId.length > 200) {
      return json({ ok: false, error: "missing_or_invalid_shopify_headers" }, 400);
    }

    const declaredLength = Number(request.headers.get("content-length") || "0");
    if (Number.isFinite(declaredLength) && declaredLength > MAX_BODY_BYTES) {
      return json({ ok: false, error: "body_too_large" }, 413);
    }

    const bodyResult = await readBoundedBody(request);
    if (bodyResult.error === "body_too_large") {
      return json({ ok: false, error: "body_too_large" }, 413);
    }
    if (bodyResult.error) return json({ ok: false, error: bodyResult.error }, 400);
    const rawBody = bodyResult.bytes;

    let validSignature = false;
    try {
      validSignature = await verifyShopifyHmac(rawBody, receivedHmac, env.SHOPIFY_API_SECRET);
    } catch {
      validSignature = false;
    }
    if (!validSignature) return json({ ok: false, error: "invalid_shopify_signature" }, 401);

    const forwardedHeaders = new Headers({
      "content-type": request.headers.get("content-type") || "application/json",
      "X-Shopify-Hmac-Sha256": receivedHmac,
      "X-Shopify-Shop-Domain": shop,
      "X-Shopify-Topic": topic,
      "X-Shopify-Webhook-Id": webhookId,
    });
    for (const name of ["X-Shopify-Event-Id", "X-Shopify-Api-Version", "X-Shopify-Triggered-At"]) {
      const value = request.headers.get(name);
      if (value) forwardedHeaders.set(name, value);
    }

    let upstream;
    try {
      upstream = await fetchImpl(env.N8N_INGEST_URL, {
        method: "POST",
        headers: forwardedHeaders,
        body: rawBody,
      });
    } catch (error) {
      console.error(JSON.stringify({
        event: "n8n_ingest_network_error",
        shop,
        topic,
        webhook_id: webhookId,
        error: error instanceof Error ? error.message : "unknown",
      }));
      return json({ ok: false, error: "ingest_forward_failed", retryable: true }, 502);
    }

    if (!upstream.ok) {
      console.error(JSON.stringify({
        event: "n8n_ingest_failed",
        status: upstream.status,
        shop,
        topic,
        webhook_id: webhookId,
      }));
      return json({
        ok: false,
        error: "ingest_forward_failed",
        retryable: true,
        upstream_status: upstream.status,
      }, 502);
    }

    return json({ ok: true, accepted: true, topic, webhook_id: webhookId }, 200);
  };
}

export default { fetch: createHandler() };

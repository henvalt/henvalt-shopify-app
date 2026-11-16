import { verifyShopifyWebhookHmac } from "./shopify-hmac.mjs";
import { buildVerifiedWebhookHeaders } from "./webhook-forwarding.mjs";
import { buildInternalAuthHeaders } from "./worker-to-n8n-auth.mjs";

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    if (request.method === "GET" && (url.pathname === "/" || url.pathname === "/health")) {
      return Response.json({ service: "henvalt-clean-ingress-v1", configured: Boolean(env.SHOPIFY_API_SECRET && env.N8N_INGEST_URL && env.HENVALT_N8N_HMAC_SECRET) }, { headers: { "cache-control": "no-store" } });
    }
    if (request.method === "OPTIONS") return new Response(null, { status: 204 });
    if (request.method !== "POST" || url.pathname !== "/shopify/webhooks") return Response.json({ error: "not_found" }, { status: 404 });
    const shop = (request.headers.get("x-shopify-shop-domain") || "").toLowerCase();
    const topic = (request.headers.get("x-shopify-topic") || "").toLowerCase();
    const hmac = request.headers.get("x-shopify-hmac-sha256") || "";
    const webhookId = request.headers.get("x-shopify-webhook-id") || request.headers.get("x-shopify-event-id") || "";
    if (!/^[a-z0-9][a-z0-9-]*\.myshopify\.com$/.test(shop) || !topic || !hmac || !webhookId) return Response.json({ error: "invalid_webhook_headers" }, { status: 400 });
    if (!env.SHOPIFY_API_SECRET || !env.N8N_INGEST_URL || !env.HENVALT_N8N_HMAC_SECRET) return Response.json({ error: "ingress_not_configured" }, { status: 503 });

    // Read exact bytes once: Shopify signs the raw request body, not a
    // decoded/re-serialized JSON representation.
    const raw = new Uint8Array(await request.arrayBuffer());
    if (raw.byteLength > 1_000_000) return Response.json({ error: "body_too_large" }, { status: 413 });
    const verified = await verifyShopifyWebhookHmac(raw, env.SHOPIFY_API_SECRET, hmac);
    if (!verified) return Response.json({ error: "invalid_hmac" }, { status: 401 });

    // Authenticate the separate Worker -> n8n hop. This secret is distinct
    // from Shopify's app secret. n8n must verify these headers before doing
    // any parsing, RPC, or side effect; deployment is unsafe until that
    // receiver-side gate and replay store are installed.
    const timestamp = String(Math.floor(Date.now() / 1000));
    const requestId = crypto.randomUUID();
    const internalAuth = await buildInternalAuthHeaders(raw, env.HENVALT_N8N_HMAC_SECRET, { timestamp, requestId });
    const forwardedHeaders = new Headers(buildVerifiedWebhookHeaders(request));
    for (const [name, value] of Object.entries(internalAuth)) forwardedHeaders.set(name, value);

    // Never pass through caller-supplied Authorization, Cookie, or forged
    // X-Henvalt-* identity/tenant headers.
    const upstream = await fetch(env.N8N_INGEST_URL, {
      method: "POST",
      headers: forwardedHeaders,
      body: raw,
    });
    if (!upstream.ok) return Response.json({ error: "ingest_unavailable" }, { status: 503 });
    const text = await upstream.text();
    return new Response(text || JSON.stringify({ accepted: true }), { status: 200, headers: { "content-type": "application/json", "cache-control": "no-store" } });
  }
};

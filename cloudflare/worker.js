import { verifyShopifyWebhookHmac } from "./shopify-hmac.mjs";
import { buildVerifiedWebhookHeaders } from "./webhook-forwarding.mjs";

const json = (status, body) => Response.json(body, { status, headers: { "cache-control": "no-store" } });
function validShop(value) { return typeof value === "string" && /^[a-z0-9][a-z0-9-]*\.myshopify\.com$/.test(value); }
function decodeRoute(pathname) {
  const prefix = "/shopify/webhooks/";
  if (!pathname.startsWith(prefix)) return null;
  const token = pathname.slice(prefix.length);
  return /^[A-Za-z0-9_-]{40,128}$/.test(token) ? token : null;
}
async function handleV2(request, env, routeToken) {
  if (!env.SUPABASE_WEBHOOK_INGRESS_URL || !env.HENVALT_INGRESS_AUTH_TOKEN) return json(503, { error: "v2_ingress_not_configured" });
  const shop = request.headers.get("x-shopify-shop-domain") || "";
  const topic = request.headers.get("x-shopify-topic") || "";
  const hmac = request.headers.get("x-shopify-hmac-sha256") || "";
  const deliveryId = request.headers.get("x-shopify-webhook-id") || "";
  const eventId = request.headers.get("x-shopify-event-id") || "";
  if (!validShop(shop) || !topic || !hmac || !deliveryId) return json(400, { error: "invalid_webhook_headers" });
  const raw = new Uint8Array(await request.arrayBuffer());
  if (raw.byteLength === 0 || raw.byteLength > 1_000_000) return json(raw.byteLength > 1_000_000 ? 413 : 400, { error: "invalid_body_size" });

  // App-specific HMAC verification happens inside the protected Supabase
  // Edge Function and Vault-backed RPC. No Shopify or service-role secret
  // is available to this Worker route.
  const headers = new Headers({
    authorization: "Bearer " + env.HENVALT_INGRESS_AUTH_TOKEN,
    "content-type": "application/octet-stream",
    "x-henvalt-route-token": routeToken,
    "x-shopify-shop-domain": shop,
    "x-shopify-topic": topic,
    "x-shopify-hmac-sha256": hmac,
    "x-shopify-webhook-id": deliveryId,
  });
  if (eventId) headers.set("x-shopify-event-id", eventId);
  let upstream;
  try {
    upstream = await fetch(env.SUPABASE_WEBHOOK_INGRESS_URL, { method: "POST", headers, body: raw });
  } catch {
    return json(503, { error: "verified_inbox_unavailable" });
  }
  const result = await upstream.json().catch(() => ({}));
  if (!upstream.ok) {
    const status = upstream.status === 401 ? 401 : upstream.status === 400 ? 400 : 503;
    return json(status, { error: typeof result.error === "string" ? result.error : "verified_inbox_rejected" });
  }
  if (result.accepted !== true) return json(503, { error: "verified_inbox_not_confirmed" });
  return json(200, { accepted: true, duplicate: result.duplicate === true, status: result.status });
}

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    if (request.method === "GET" && (url.pathname === "/" || url.pathname === "/health")) {
      return json(200, { service: "henvalt-clean-ingress-v1", legacy_configured: Boolean(env.SHOPIFY_API_SECRET && env.N8N_INGEST_URL), v2_configured: Boolean(env.SUPABASE_WEBHOOK_INGRESS_URL && env.HENVALT_INGRESS_AUTH_TOKEN) });
    }
    if (request.method !== "POST") return json(404, { error: "not_found" });
    const routeToken = decodeRoute(url.pathname);
    if (routeToken) return handleV2(request, env, routeToken);

    // Legacy route remains untouched until a separately approved cutover.
    if (url.pathname !== "/shopify/webhooks") return json(404, { error: "not_found" });
    const shop = (request.headers.get("x-shopify-shop-domain") || "").toLowerCase();
    const topic = (request.headers.get("x-shopify-topic") || "").toLowerCase();
    const hmac = request.headers.get("x-shopify-hmac-sha256") || "";
    const webhookId = request.headers.get("x-shopify-webhook-id") || request.headers.get("x-shopify-event-id") || "";
    if (!validShop(shop) || !topic || !hmac || !webhookId) return json(400, { error: "invalid_webhook_headers" });
    if (!env.SHOPIFY_API_SECRET || !env.N8N_INGEST_URL) return json(503, { error: "ingress_not_configured" });
    const raw = new Uint8Array(await request.arrayBuffer());
    if (raw.byteLength > 1_000_000) return json(413, { error: "body_too_large" });
    const verified = await verifyShopifyWebhookHmac(raw, env.SHOPIFY_API_SECRET, hmac);
    if (!verified) return json(401, { error: "invalid_hmac" });
    const forwardedHeaders = new Headers(buildVerifiedWebhookHeaders(request));
    const upstream = await fetch(env.N8N_INGEST_URL, { method: "POST", headers: forwardedHeaders, body: raw });
    if (!upstream.ok) return json(503, { error: "ingest_unavailable" });
    const text = await upstream.text();
    return new Response(text || JSON.stringify({ accepted: true }), { status: 200, headers: { "content-type": "application/json", "cache-control": "no-store" } });
  },
};

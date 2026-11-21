import { verifyShopifyWebhookHmac } from "./shopify-hmac.mjs";
import { buildVerifiedWebhookHeaders } from "./webhook-forwarding.mjs";

const json = (status, body) => Response.json(body, { status, headers: { "cache-control": "no-store" } });
function validShop(value) { return typeof value === "string" && /^[a-z0-9][a-z0-9-]*\.myshopify\.com$/.test(value); }
function validIngressUrl(value) {
  try {
    const url = new URL(value);
    return url.protocol === "https:" && url.hostname === "ocyplckdojdubyrsxcxa.supabase.co" && !url.port &&
      url.pathname === "/functions/v1/henvalt-shopify-webhook-ingress" &&
      !url.username && !url.password && !url.search && !url.hash;
  } catch { return false; }
}
async function readBoundedBody(request, maxBytes) {
  const declared = request.headers.get("content-length");
  if (declared !== null) {
    if (!/^\d+$/.test(declared)) return { error: "invalid_content_length" };
    if (Number(declared) > maxBytes) return { error: "body_too_large" };
  }
  const reader = request.body?.getReader();
  if (!reader) return { error: "empty_body" };
  const chunks = []; let total = 0;
  try {
    while (true) {
      const part = await reader.read();
      if (part.done) break;
      total += part.value.byteLength;
      if (total > maxBytes) {
        try { await reader.cancel(); } catch { /* bounded read remains authoritative */ }
        return { error: "body_too_large" };
      }
      chunks.push(part.value);
    }
  } catch { return { error: "body_read_failed" }; }
  finally { try { reader.releaseLock(); } catch { /* already released */ } }
  if (!total) return { error: "empty_body" };
  const bytes = new Uint8Array(total); let offset = 0;
  for (const chunk of chunks) { bytes.set(chunk, offset); offset += chunk.byteLength; }
  return { bytes };
}
async function readBoundedJson(response, maxBytes = 16_384) {
  const declared = response.headers.get("content-length");
  if (declared !== null && (!/^\d+$/.test(declared) || Number(declared) > maxBytes)) return null;
  const reader = response.body?.getReader();
  if (!reader) return null;
  const chunks = []; let total = 0;
  try {
    while (true) {
      const part = await reader.read();
      if (part.done) break;
      total += part.value.byteLength;
      if (total > maxBytes) {
        try { await reader.cancel(); } catch { /* response remains rejected */ }
        return null;
      }
      chunks.push(part.value);
    }
  } catch { return null; }
  finally { try { reader.releaseLock(); } catch { /* already released */ } }
  try {
    const bytes = new Uint8Array(total); let offset = 0;
    for (const chunk of chunks) { bytes.set(chunk, offset); offset += chunk.byteLength; }
    const value = JSON.parse(new TextDecoder().decode(bytes));
    return value && typeof value === "object" && !Array.isArray(value) ? value : null;
  } catch { return null; }
}
function decodeRoute(pathname) {
  const prefix = "/shopify/webhooks/";
  if (!pathname.startsWith(prefix)) return null;
  const token = pathname.slice(prefix.length);
  return /^[A-Za-z0-9_-]{40,128}$/.test(token) ? token : null;
}
async function handleV2(request, env, routeToken) {
  if (!validIngressUrl(env.SUPABASE_WEBHOOK_INGRESS_URL) || !env.HENVALT_INGRESS_AUTH_TOKEN) return json(503, { error: "v2_ingress_not_configured" });
  const shop = request.headers.get("x-shopify-shop-domain") || "";
  const topic = request.headers.get("x-shopify-topic") || "";
  const hmac = request.headers.get("x-shopify-hmac-sha256") || "";
  const deliveryId = request.headers.get("x-shopify-webhook-id") || "";
  const eventId = request.headers.get("x-shopify-event-id") || "";
  if (!validShop(shop) || !/^[a-z0-9_./-]{1,128}$/.test(topic) || !/^[A-Za-z0-9+/]{43}=$/.test(hmac) || !deliveryId || deliveryId.length > 255 || eventId.length > 255) return json(400, { error: "invalid_webhook_headers" });
  const body = await readBoundedBody(request, 1_000_000);
  if (body.error) return json(body.error === "body_too_large" ? 413 : 400, { error: body.error });

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
    upstream = await fetch(env.SUPABASE_WEBHOOK_INGRESS_URL, { method: "POST", headers, body: body.bytes, signal: AbortSignal.timeout(8_000) });
  } catch {
    return json(503, { error: "verified_inbox_unavailable" });
  }
  const result = await readBoundedJson(upstream);
  if (!result) return json(503, { error: "verified_inbox_invalid_response" });
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
      return json(200, { service: "henvalt-clean-ingress-v1", legacy_configured: Boolean(env.SHOPIFY_API_SECRET && env.N8N_INGEST_URL), v2_configured: Boolean(validIngressUrl(env.SUPABASE_WEBHOOK_INGRESS_URL) && env.HENVALT_INGRESS_AUTH_TOKEN) });
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

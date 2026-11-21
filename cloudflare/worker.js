export async function handleRequest(request, env, fetchImpl = fetch) {
  const url = new URL(request.url);
  if (request.method === "GET" && (url.pathname === "/" || url.pathname === "/health")) {
    return Response.json({ service: "henvalt-clean-ingress-v1", configured: Boolean(env.SHOPIFY_API_SECRET && env.N8N_INGEST_URL) }, { headers: { "cache-control": "no-store" } });
  }
  if (request.method === "OPTIONS") return new Response(null, { status: 204 });
  if (request.method !== "POST" || url.pathname !== "/shopify/webhooks") return Response.json({ error: "not_found" }, { status: 404 });

  // Fail closed before reading or forwarding a delivery when ingress is misconfigured.
  if (typeof env.SHOPIFY_API_SECRET !== "string" || !env.SHOPIFY_API_SECRET ||
      typeof env.N8N_INGEST_URL !== "string" || !/^https:\/\//i.test(env.N8N_INGEST_URL)) {
    return Response.json({ error: "ingress_configuration_missing" }, { status: 503 });
  }

  const shop = (request.headers.get("x-shopify-shop-domain") || "").toLowerCase();
  const topic = (request.headers.get("x-shopify-topic") || "").toLowerCase();
  const hmac = request.headers.get("x-shopify-hmac-sha256") || "";
  const webhookId = request.headers.get("x-shopify-webhook-id") || request.headers.get("x-shopify-event-id") || "";
  if (!/^[a-z0-9][a-z0-9-]*\.myshopify\.com$/.test(shop) || !topic || !hmac || !webhookId) return Response.json({ error: "invalid_webhook_headers" }, { status: 400 });

  const contentLength = Number(request.headers.get("content-length") || "0");
  if (Number.isFinite(contentLength) && contentLength > 1_000_000) return Response.json({ error: "body_too_large" }, { status: 413 });
  const raw = await request.text();
  if (new TextEncoder().encode(raw).byteLength > 1_000_000) return Response.json({ error: "body_too_large" }, { status: 413 });

  const key = await crypto.subtle.importKey("raw", new TextEncoder().encode(env.SHOPIFY_API_SECRET), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const sig = new Uint8Array(await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(raw)));
  const expected = btoa(String.fromCharCode(...sig));
  if (!constantTimeEqual(expected, hmac)) return Response.json({ error: "invalid_hmac" }, { status: 401 });

  const upstream = await fetchImpl(env.N8N_INGEST_URL, { method: "POST", headers: request.headers, body: raw });
  if (!upstream.ok) return Response.json({ error: "ingest_unavailable" }, { status: 503 });
  const text = await upstream.text();
  return new Response(text || JSON.stringify({ accepted: true }), { status: 200, headers: { "content-type": "application/json", "cache-control": "no-store" } });
}

export default {
  fetch(request, env) {
    return handleRequest(request, env);
  }
};

function constantTimeEqual(a, b) {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}

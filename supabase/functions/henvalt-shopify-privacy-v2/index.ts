import "jsr:@supabase/functions-js/edge-runtime.d.ts";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL") ?? "";
const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
const SHOPIFY_API_KEY = Deno.env.get("SHOPIFY_API_KEY") ?? "";

const json = (status: number, body: Record<string, unknown>) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json", "cache-control": "no-store" },
  });

function base64(bytes: Uint8Array): string {
  let binary = "";
  for (let i = 0; i < bytes.length; i += 0x8000) {
    binary += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
  }
  return btoa(binary);
}

async function resolveActiveAppKey(): Promise<string | null> {
  const response = await fetch(SUPABASE_URL + "/rest/v1/rpc/resolve_shopify_app_oauth_identity", {
    method: "POST",
    headers: {
      apikey: SERVICE_ROLE_KEY,
      authorization: "Bearer " + SERVICE_ROLE_KEY,
      "content-type": "application/json",
      "accept-profile": "henvalt",
      "content-profile": "henvalt",
    },
    body: JSON.stringify({ p_shopify_client_id: SHOPIFY_API_KEY }),
  });
  if (!response.ok) {
    console.error("Privacy app identity resolution failed", response.status);
    return null;
  }
  const payload = await response.json().catch(() => null);
  const row = Array.isArray(payload) ? payload[0] : payload;
  if (!row || typeof row.app_key !== "string" ||
      !/^[a-z][a-z0-9_-]{2,63}$/.test(row.app_key) ||
      row.shopify_client_id !== SHOPIFY_API_KEY ||
      typeof row.shopify_api_secret !== "string" || row.shopify_api_secret.length < 1) {
    return null;
  }
  // SQL owns HMAC verification; this function never logs or returns the secret.
  return row.app_key;
}

Deno.serve(async (req: Request) => {
  if (req.method !== "POST") return json(405, { error: "method_not_allowed" });
  if (!SUPABASE_URL || !SERVICE_ROLE_KEY || !SHOPIFY_API_KEY) {
    return json(503, { error: "privacy_ingress_not_configured" });
  }

  // Resolve the app key from the trusted registry, never from a caller-controlled path.
  const appKey = await resolveActiveAppKey();
  if (!appKey) return json(503, { error: "privacy_app_identity_unavailable" });

  const topic = (req.headers.get("x-shopify-topic") ?? "").toLowerCase();
  const shop = (req.headers.get("x-shopify-shop-domain") ?? "").toLowerCase();
  const webhookId = req.headers.get("x-shopify-webhook-id") ?? "";
  const hmac = req.headers.get("x-shopify-hmac-sha256") ?? "";
  if (!["customers/data_request", "customers/redact", "shop/redact"].includes(topic) ||
      !/^[a-z0-9][a-z0-9-]*\.myshopify\.com$/.test(shop) ||
      webhookId.length < 1 || webhookId.length > 255 ||
      !/^[A-Za-z0-9+/]{43}=$/.test(hmac)) {
    return json(400, { error: "invalid_compliance_webhook_headers" });
  }

  const raw = new Uint8Array(await req.arrayBuffer());
  if (raw.length === 0 || raw.length > 1_048_576) {
    return json(413, { error: "invalid_body_size" });
  }

  const response = await fetch(SUPABASE_URL + "/rest/v1/rpc/accept_shopify_privacy_webhook_v2", {
    method: "POST",
    headers: {
      apikey: SERVICE_ROLE_KEY,
      authorization: "Bearer " + SERVICE_ROLE_KEY,
      "content-type": "application/json",
      "accept-profile": "henvalt",
      "content-profile": "henvalt",
    },
    body: JSON.stringify({
      p_app_key: appKey,
      p_shopify_client_id: SHOPIFY_API_KEY,
      p_hmac_base64: hmac,
      p_raw_body_base64: base64(raw),
      p_shop_domain: shop,
      p_topic: topic,
      p_webhook_id: webhookId,
    }),
  });

  if (!response.ok) {
    console.error("Privacy inbox RPC failed", response.status);
    return json(503, { error: "privacy_inbox_unavailable" });
  }

  const payload = await response.json().catch(() => null);
  const row = Array.isArray(payload) ? payload[0] : payload;
  if (!row || typeof row.accepted !== "boolean") {
    return json(503, { error: "privacy_inbox_invalid_response" });
  }
  if (!row.accepted) {
    const code = typeof row.rejection_code === "string" ? row.rejection_code : "privacy_webhook_rejected";
    const status = code === "HMAC_INVALID" ? 401 :
      code === "SHOP_DOMAIN_MISMATCH" ? 403 :
      code === "INVALID_REQUEST" ? 400 : 503;
    return json(status, { error: code.toLowerCase() });
  }

  // A 200 means Shopify's verified request is durably recorded, not that
  // deletion/export has completed. Exact-store processing is a separate gate.
  return json(200, {
    received: true,
    duplicate: row.duplicate === true,
    review_required: true,
    status: row.receipt_status,
  });
});

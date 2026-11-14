import "jsr:@supabase/functions-js/edge-runtime.d.ts";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL") ?? "";
const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
const SHOPIFY_API_SECRET = Deno.env.get("SHOPIFY_API_SECRET") ?? "";

function json(status: number, body: Record<string, unknown>) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json", "cache-control": "no-store" },
  });
}
function safeEqual(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}
async function verifyHmac(raw: string, supplied: string): Promise<boolean> {
  if (!SHOPIFY_API_SECRET || !supplied) return false;
  const key = await crypto.subtle.importKey(
    "raw", new TextEncoder().encode(SHOPIFY_API_SECRET),
    { name: "HMAC", hash: "SHA-256" }, false, ["sign"],
  );
  const signature = new Uint8Array(await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(raw)));
  const expected = btoa(String.fromCharCode(...signature));
  return safeEqual(expected, supplied);
}
async function db(path: string, init: RequestInit = {}) {
  return fetch(SUPABASE_URL + path, {
    ...init,
    headers: {
      apikey: SERVICE_ROLE_KEY,
      authorization: "Bearer " + SERVICE_ROLE_KEY,
      "content-type": "application/json",
      "accept-profile": "henvalt",
      "content-profile": "henvalt",
      ...(init.headers ?? {}),
    },
  });
}

Deno.serve(async (req: Request) => {
  if (req.method !== "POST") return json(405, { error: "method_not_allowed" });
  if (!SUPABASE_URL || !SERVICE_ROLE_KEY || !SHOPIFY_API_SECRET) {
    return json(503, { error: "privacy_handler_not_configured" });
  }
  const topic = (req.headers.get("x-shopify-topic") ?? "").toLowerCase();
  const shop = (req.headers.get("x-shopify-shop-domain") ?? "").toLowerCase();
  const shopId = req.headers.get("x-shopify-shop-id") ?? "";
  const webhookId = req.headers.get("x-shopify-webhook-id") ?? "";
  const hmac = req.headers.get("x-shopify-hmac-sha256") ?? "";
  if (!["customers/data_request", "customers/redact", "shop/redact"].includes(topic) ||
      !/^[a-z0-9][a-z0-9-]*\.myshopify\.com$/.test(shop) || !webhookId || !hmac) {
    return json(400, { error: "invalid_compliance_webhook_headers" });
  }
  const raw = await req.text();
  if (raw.length > 1_000_000) return json(413, { error: "payload_too_large" });
  if (!(await verifyHmac(raw, hmac))) return json(401, { error: "invalid_hmac" });
  // Opportunistically erase expired export bundles whenever a verified compliance webhook arrives.
  const purge = await db("/rest/v1/rpc/purge_expired_shopify_privacy_exports", {
    method: "POST",
    body: "{}",
  });
  if (!purge.ok) console.error("Expired privacy export cleanup failed", purge.status);
  let payload: any;
  try { payload = JSON.parse(raw); } catch { return json(400, { error: "invalid_json" }); }
  if (payload?.shop_domain && String(payload.shop_domain).toLowerCase() !== shop) {
    return json(400, { error: "shop_domain_mismatch" });
  }
  const connection = await db(
    "/rest/v1/shopify_connections?select=tenant_id,shopify_shop_id&shop_domain=eq." +
      encodeURIComponent(shop) + "&limit=1",
  );
  if (!connection.ok) return json(503, { error: "tenant_lookup_failed" });
  const rows = await connection.json().catch(() => []);
  const row = Array.isArray(rows) ? rows[0] : null;
  // Preserve valid Shopify requests even when the shop is no longer linked.
  // Returning 200 without persisting would silently discard a compliance request.
  const matched = Boolean(row?.tenant_id);
  const customerId = payload?.customer?.id == null ? null : String(payload.customer.id);
  const customerEmail = payload?.customer?.email == null ? null : String(payload.customer.email);
  const requestId = payload?.data_request?.id == null ? null : String(payload.data_request.id);
  const inserted = await db("/rest/v1/shopify_privacy_requests?on_conflict=webhook_id", {
    method: "POST",
    headers: { prefer: "resolution=ignore-duplicates,return=minimal" },
    body: JSON.stringify({
      tenant_id: row?.tenant_id ?? null,
      shop_domain: shop,
      shopify_shop_id: shopId || row?.shopify_shop_id || null,
      topic,
      webhook_id: webhookId,
      customer_id: customerId,
      request_id: requestId,
      payload,
      status: matched ? "PENDING" : "REVIEW_REQUIRED",
    }),
  });
  if (!inserted.ok) {
    console.error("Privacy request persistence failed", inserted.status);
    return json(503, { error: "privacy_request_persistence_failed" });
  }

  const lookup = await db(
    "/rest/v1/shopify_privacy_requests?select=id,status&webhook_id=eq." +
      encodeURIComponent(webhookId) + "&limit=1",
  );
  if (!lookup.ok) return json(503, { error: "privacy_request_lookup_failed" });
  const storedRows = await lookup.json().catch(() => []);
  const stored = Array.isArray(storedRows) ? storedRows[0] : null;
  if (!stored?.id) return json(503, { error: "privacy_request_record_missing" });
  if (stored.status === "COMPLETED") {
    return json(200, { received: true, processed: true, duplicate: true, topic });
  }
  if (!matched) {
    return json(200, { received: true, queued: true, matched: false, review_required: true, topic });
  }

  const requestUrl = "/rest/v1/shopify_privacy_requests?id=eq." + encodeURIComponent(stored.id);
  const patch = async (body: Record<string, unknown>) => db(requestUrl, {
    method: "PATCH",
    headers: { prefer: "return=minimal" },
    body: JSON.stringify(body),
  });
  const rpc = async (name: string, body: Record<string, unknown>) => db("/rest/v1/rpc/" + name, {
    method: "POST",
    body: JSON.stringify(body),
  });

  if (topic === "customers/data_request") {
    if (!customerId && !customerEmail) {
      await patch({ status: "REVIEW_REQUIRED", last_error: "customer_identifier_missing" });
      return json(200, { received: true, review_required: true, reason: "customer_identifier_missing" });
    }
    const exported = await rpc("export_shopify_customer_data", {
      p_tenant_id: row.tenant_id,
      p_shopify_customer_id: customerId,
      p_customer_email: customerEmail,
    });
    if (!exported.ok) {
      await patch({ status: "FAILED", last_error: "customer_export_failed" });
      return json(503, { error: "customer_export_failed" });
    }
    const result = await exported.json();
    const exportFound = result?.found === true;
    const saved = await patch({
      result_payload: exportFound ? result : null,
      payload: exportFound ? {} : payload,
      customer_id: exportFound ? null : customerId,
      result_expires_at: exportFound ? new Date(Date.now() + 30 * 24 * 60 * 60 * 1000).toISOString() : null,
      status: "REVIEW_REQUIRED",
      last_error: exportFound ? "export_ready_for_secure_merchant_delivery" : "customer_record_not_found",
    });
    if (!saved.ok) return json(503, { error: "customer_export_persistence_failed" });
    return json(200, {
      received: true,
      export_generated: exportFound,
      awaiting_secure_delivery: exportFound,
      review_required: !exportFound,
    });
  }

  if (topic === "customers/redact") {
    if (!customerId && !customerEmail) {
      await patch({ status: "REVIEW_REQUIRED", last_error: "customer_identifier_missing" });
      return json(200, { received: true, review_required: true, reason: "customer_identifier_missing" });
    }
    const redacted = await rpc("redact_shopify_customer_data", {
      p_tenant_id: row.tenant_id,
      p_shopify_customer_id: customerId,
      p_customer_email: customerEmail,
    });
    if (!redacted.ok) {
      await patch({ status: "FAILED", last_error: "customer_redaction_failed" });
      return json(503, { error: "customer_redaction_failed" });
    }
    const result = await redacted.json();
    if (!result?.matched) {
      await patch({ status: "REVIEW_REQUIRED", last_error: "customer_record_not_found" });
      return json(200, { received: true, review_required: true, reason: "customer_record_not_found" });
    }
    const saved = await patch({ status: "COMPLETED", payload: {}, customer_id: null, processed_at: new Date().toISOString(), last_error: null });
    if (!saved.ok) return json(503, { error: "customer_redaction_status_update_failed" });
    return json(200, { received: true, processed: true, topic });
  }

  if (topic === "shop/redact") {
    const redacted = await rpc("redact_shopify_shop_data", { p_privacy_request_id: stored.id });
    if (!redacted.ok) {
      await patch({ status: "FAILED", last_error: "shop_redaction_failed" });
      return json(503, { error: "shop_redaction_failed" });
    }
    return json(200, { received: true, processed: true, topic });
  }

  return json(200, { received: true, queued: true, matched, topic });
});

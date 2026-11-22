// CANDIDATE ONLY — lease-backed Shopify compliance handler.
// Requires candidate migrations 202611220001 and 202611220002.
// Do not deploy until disposable PostgreSQL acceptance and full lifecycle review pass.
import "jsr:@supabase/functions-js/edge-runtime.d.ts";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL") ?? "";
const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
const SHOPIFY_API_SECRET = Deno.env.get("SHOPIFY_API_SECRET") ?? "";

type Json = Record<string, unknown>;

const reply = (status: number, body: Json) => new Response(JSON.stringify(body), {
  status,
  headers: { "content-type": "application/json; charset=utf-8", "cache-control": "no-store" },
});

function safeEqual(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}

async function verifyHmac(raw: Uint8Array, supplied: string): Promise<boolean> {
  if (!SHOPIFY_API_SECRET || !supplied) return false;
  const key = await crypto.subtle.importKey(
    "raw", new TextEncoder().encode(SHOPIFY_API_SECRET),
    { name: "HMAC", hash: "SHA-256" }, false, ["sign"],
  );
  const signature = new Uint8Array(await crypto.subtle.sign("HMAC", key, raw));
  const expected = btoa(String.fromCharCode(...signature));
  return safeEqual(expected, supplied);
}

async function db(path: string, init: RequestInit = {}): Promise<Response> {
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

async function rpc(name: string, body: Json): Promise<Response> {
  return db("/rest/v1/rpc/" + name, { method: "POST", body: JSON.stringify(body) });
}

function asId(value: unknown): string | null {
  if (typeof value === "string" || typeof value === "number") {
    const result = String(value).trim();
    return result.length > 0 && result.length <= 128 ? result : null;
  }
  return null;
}

Deno.serve(async (req: Request) => {
  if (req.method !== "POST") return reply(405, { error: "method_not_allowed" });
  if (!SUPABASE_URL || !SERVICE_ROLE_KEY || !SHOPIFY_API_SECRET) {
    return reply(503, { error: "privacy_handler_not_configured" });
  }

  const topic = (req.headers.get("x-shopify-topic") ?? "").toLowerCase();
  const shop = (req.headers.get("x-shopify-shop-domain") ?? "").toLowerCase();
  const webhookId = req.headers.get("x-shopify-webhook-id") ?? "";
  const hmac = req.headers.get("x-shopify-hmac-sha256") ?? "";
  if (!["customers/data_request", "customers/redact", "shop/redact"].includes(topic) ||
      !/^[a-z0-9][a-z0-9-]*\.myshopify\.com$/.test(shop) ||
      !/^[a-zA-Z0-9_-]{1,128}$/.test(webhookId) || !hmac) {
    return reply(400, { error: "invalid_compliance_webhook_headers" });
  }

  const raw = new Uint8Array(await req.arrayBuffer());
  if (raw.byteLength > 1_000_000) return reply(413, { error: "payload_too_large" });
  if (!(await verifyHmac(raw, hmac))) return reply(401, { error: "invalid_hmac" });

  let payload: any;
  try {
    payload = JSON.parse(new TextDecoder().decode(raw));
  } catch {
    return reply(400, { error: "invalid_json" });
  }

  // shop_id is part of the HMAC-covered body. The X-Shopify-Shop-Id header is deliberately ignored.
  const signedShopId = asId(payload?.shop_id);
  if (!signedShopId) return reply(400, { error: "signed_shop_id_missing" });
  if (payload?.shop_domain && String(payload.shop_domain).toLowerCase() !== shop) {
    return reply(400, { error: "signed_shop_domain_mismatch" });
  }

  const connectionResponse = await db(
    "/rest/v1/shopify_connections?select=tenant_id,shopify_shop_id&shop_domain=eq." +
    encodeURIComponent(shop) + "&active=eq.true&limit=2",
  );
  if (!connectionResponse.ok) return reply(503, { error: "tenant_lookup_failed" });
  const connections = await connectionResponse.json().catch(() => []);
  if (!Array.isArray(connections) || connections.length > 1) {
    return reply(503, { error: "shop_connection_not_unique" });
  }
  const connection = connections[0] ?? null;
  if (connection && String(connection.shopify_shop_id ?? "") !== signedShopId) {
    return reply(401, { error: "signed_shop_identity_mismatch" });
  }

  const customerId = asId(payload?.customer?.id);
  const customerEmail = typeof payload?.customer?.email === "string"
    ? payload.customer.email.trim().toLowerCase().slice(0, 320) : null;
  const requestId = asId(payload?.data_request?.id);
  if (topic !== "shop/redact" && !customerId && !customerEmail) {
    return reply(400, { error: "customer_identifier_missing" });
  }

  // Persist only the identifiers required for the operation, never the raw webhook body.
  // Email is retained only for the data-request/redaction operation and cleared at terminal state.
  const minimalPayload = customerEmail ? { customer_email: customerEmail } : {};
  const tenantId = connection?.tenant_id ?? null;
  const initialStatus = connection ? "PENDING" : "REVIEW_REQUIRED";
  const inserted = await db("/rest/v1/shopify_privacy_requests?on_conflict=webhook_id", {
    method: "POST",
    headers: { prefer: "resolution=ignore-duplicates,return=minimal" },
    body: JSON.stringify({
      tenant_id: tenantId,
      shop_domain: shop,
      shopify_shop_id: signedShopId,
      topic,
      webhook_id: webhookId,
      customer_id: customerId,
      request_id: requestId,
      payload: minimalPayload,
      status: initialStatus,
    }),
  });
  if (!inserted.ok) return reply(503, { error: "privacy_request_persistence_failed" });

  const lookup = await db(
    "/rest/v1/shopify_privacy_requests?select=id,status&webhook_id=eq." +
    encodeURIComponent(webhookId) + "&limit=1",
  );
  if (!lookup.ok) return reply(503, { error: "privacy_request_lookup_failed" });
  const storedRows = await lookup.json().catch(() => []);
  const stored = Array.isArray(storedRows) ? storedRows[0] : null;
  if (!stored?.id) return reply(503, { error: "privacy_request_record_missing" });
  if (stored.status === "COMPLETED") {
    return reply(200, { received: true, processed: true, duplicate: true, topic });
  }
  if (!connection || stored.status === "REVIEW_REQUIRED") {
    return reply(200, { received: true, queued: true, review_required: true, topic });
  }

  const claimResponse = await rpc("claim_shopify_privacy_request_by_id", {
    p_request_id: stored.id,
    p_lease_seconds: 120,
  });
  if (!claimResponse.ok) return reply(503, { error: "privacy_request_claim_failed" });
  const claims = await claimResponse.json().catch(() => []);
  const claim = Array.isArray(claims) ? claims[0] : null;
  if (!claim?.lease_token) {
    return reply(200, { received: true, queued: true, duplicate: true, topic });
  }

  const finish = async (status: "COMPLETED" | "FAILED" | "REVIEW_REQUIRED", errorCode: string | null) => {
    const result = await rpc("finish_shopify_privacy_request", {
      p_request_id: claim.id,
      p_lease_token: claim.lease_token,
      p_status: status,
      p_error_code: errorCode,
    });
    if (!result.ok) return false;
    return await result.json().catch(() => false) === true;
  };

  try {
    if (topic === "customers/data_request") {
      const exported = await rpc("export_shopify_customer_data", {
        p_tenant_id: claim.tenant_id,
        p_shopify_customer_id: customerId,
        p_customer_email: customerEmail,
      });
      if (!exported.ok) {
        await finish("FAILED", "customer_export_failed");
        return reply(503, { error: "customer_export_failed" });
      }
      const result = await exported.json();
      const found = result?.found === true;
      if (found) {
        const saved = await db(
          "/rest/v1/shopify_privacy_requests?id=eq." + encodeURIComponent(claim.id),
          {
            method: "PATCH",
            headers: { prefer: "return=minimal" },
            body: JSON.stringify({
              result_payload: result,
              result_expires_at: new Date(Date.now() + 30 * 24 * 60 * 60 * 1000).toISOString(),
            }),
          },
        );
        if (!saved.ok) {
          await finish("FAILED", "customer_export_persistence_failed");
          return reply(503, { error: "customer_export_persistence_failed" });
        }
      }
      const completed = await finish("REVIEW_REQUIRED",
        found ? "export_ready_for_secure_merchant_delivery" : "customer_record_not_found");
      if (!completed) return reply(503, { error: "privacy_request_lease_lost" });
      return reply(200, {
        received: true, export_generated: found,
        awaiting_secure_delivery: found, review_required: true,
      });
    }

    if (topic === "customers/redact") {
      const redacted = await rpc("redact_shopify_customer_data_checked", {
        p_tenant_id: claim.tenant_id,
        p_shopify_customer_id: customerId,
        p_customer_email: customerEmail,
      });
      if (!redacted.ok) {
        await finish("FAILED", "customer_redaction_failed");
        return reply(503, { error: "customer_redaction_failed" });
      }
      const result = await redacted.json();
      const matched = result?.matched === true;
      const completed = await finish(
        matched ? "COMPLETED" : "REVIEW_REQUIRED",
        matched ? null : "customer_record_not_found",
      );
      if (!completed) return reply(503, { error: "privacy_request_lease_lost" });
      return reply(200, { received: true, processed: matched, review_required: !matched, topic });
    }

    const redacted = await rpc("redact_shopify_shop_data_with_lease", {
      p_privacy_request_id: claim.id,
      p_lease_token: claim.lease_token,
    });
    if (!redacted.ok) {
      await finish("FAILED", "shop_redaction_failed");
      return reply(503, { error: "shop_redaction_failed" });
    }
    return reply(200, { received: true, processed: true, topic });
  } catch {
    // A retry may reclaim FAILED immediately or PROCESSING after lease expiry.
    await finish("FAILED", "privacy_processing_exception");
    return reply(503, { error: "privacy_processing_failed" });
  }
});

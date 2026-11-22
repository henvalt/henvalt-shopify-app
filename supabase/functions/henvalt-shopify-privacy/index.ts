// CANDIDATE ONLY — lease-backed Shopify compliance handler.
// Requires candidate migrations 202611220001 and 202611220002.
// Do not deploy until disposable PostgreSQL acceptance and full lifecycle review pass.
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { readBoundedBody } from "./body-limiter.mjs";

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
  try {
    return await fetch(SUPABASE_URL + path, {
      ...init,
      signal: init.signal ?? AbortSignal.timeout(1800),
      headers: {
        apikey: SERVICE_ROLE_KEY,
        authorization: "Bearer " + SERVICE_ROLE_KEY,
        "content-type": "application/json",
        "accept-profile": "henvalt",
        "content-profile": "henvalt",
        ...(init.headers ?? {}),
      },
    });
  } catch {
    return new Response(JSON.stringify({ error: "database_unavailable" }), {
      status: 503,
      headers: { "content-type": "application/json; charset=utf-8", "cache-control": "no-store" },
    });
  }
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
  const contentType = (req.headers.get("content-type") ?? "").split(";")[0].trim().toLowerCase();
  if (contentType !== "application/json") return reply(415, { error: "application_json_required" });
  if (!SUPABASE_URL || !SERVICE_ROLE_KEY || !SHOPIFY_API_SECRET) {
    return reply(503, { error: "privacy_handler_not_configured" });
  }

  const topic = (req.headers.get("x-shopify-topic") ?? "").toLowerCase();
  const shop = (req.headers.get("x-shopify-shop-domain") ?? "").toLowerCase();
  const webhookId = req.headers.get("x-shopify-webhook-id") ?? "";
  const hmac = req.headers.get("x-shopify-hmac-sha256") ?? "";
  if (!hmac) return reply(401, { error: "invalid_hmac" });
  if (!["customers/data_request", "customers/redact", "shop/redact"].includes(topic) ||
      !/^[a-z0-9][a-z0-9-]*\.myshopify\.com$/.test(shop) ||
      !/^[a-zA-Z0-9_-]{1,128}$/.test(webhookId)) {
    return reply(400, { error: "invalid_compliance_webhook_headers" });
  }

  let boundedBody: Awaited<ReturnType<typeof readBoundedBody>>;
  try {
    boundedBody = await readBoundedBody(req, MAX_BODY_BYTES);
  } catch {
    return reply(503, { error: "request_body_read_failed" });
  }
  if (!boundedBody.ok) return reply(413, { error: "payload_too_large" });
  const raw = boundedBody.bytes;
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
    encodeURIComponent(shop) + "&limit=2",
  );
  if (!connectionResponse.ok) return reply(503, { error: "tenant_lookup_failed" });
  const connections = await connectionResponse.json().catch(() => null);
  if (!Array.isArray(connections) || connections.length > 1) {
    return reply(503, { error: "shop_connection_not_unique" });
  }
  const connection = connections[0] ?? null;
  if (connection?.shopify_shop_id && String(connection.shopify_shop_id) !== signedShopId) {
    return reply(401, { error: "signed_shop_identity_mismatch" });
  }
  // A legacy row without a stored Shopify ID is not a verified tenant mapping.
  const verifiedConnection = connection?.shopify_shop_id &&
      String(connection.shopify_shop_id) === signedShopId ? connection : null;

  const customerId = asId(payload?.customer?.id);
  const rawCustomerEmail = typeof payload?.customer?.email === "string"
    ? payload.customer.email.trim() : null;
  if (rawCustomerEmail && rawCustomerEmail.length > 320) {
    return reply(400, { error: "customer_email_too_long" });
  }
  const customerEmail = rawCustomerEmail ? rawCustomerEmail.toLowerCase() : null;
  // Retain only the email required for tenant-scoped export/redaction; never the raw webhook body.
  const minimalPayload = { shop_id: signedShopId, customer_email: customerEmail };
  const requestId = asId(payload?.data_request?.id);
  if (topic !== "shop/redact" && !customerId && !customerEmail) {
    return reply(400, { error: "customer_identifier_missing" });
  }

  // Hash the HMAC-covered bytes: webhook ID is an unsigned header and cannot be the sole replay key.
  const digest = new Uint8Array(await crypto.subtle.digest("SHA-256", raw));
  const signedPayloadHash = Array.from(digest, (byte) => byte.toString(16).padStart(2, "0")).join("");

  // Persist only minimal identifiers. The database RPC deduplicates by signed payload hash
  // and also rejects reuse of one webhook ID with a different signed body.
  const initialStatus = verifiedConnection ? "PENDING" : "REVIEW_REQUIRED";
  const persisted = await rpc("persist_shopify_privacy_request", {
    p_tenant_id: verifiedConnection?.tenant_id ?? null,
    p_shop_domain: shop,
    p_shopify_shop_id: signedShopId,
    p_topic: topic,
    p_webhook_id: webhookId,
    p_signed_payload_hash: signedPayloadHash,
    p_customer_id: verifiedConnection ? customerId : null,
    p_request_id: requestId,
    p_payload: verifiedConnection ? minimalPayload : {},
    p_status: initialStatus,
  });
  if (!persisted.ok) {
    return reply(persisted.status === 400 ? 409 : 503, {
      error: persisted.status === 400 ? "privacy_webhook_id_payload_conflict" : "privacy_request_persistence_failed",
    });
  }
  const persistedRows = await persisted.json().catch(() => []);
  const stored = Array.isArray(persistedRows) ? persistedRows[0] : null;
  if (!stored?.id) return reply(503, { error: "privacy_request_record_missing" });

  if (stored.status === "COMPLETED") {
    return reply(200, { received: true, processed: true, duplicate: true, topic });
  }
  if (!verifiedConnection || stored.status === "REVIEW_REQUIRED") {
    return reply(200, { received: true, queued: true, review_required: true, topic });
  }

  // Acknowledge only after durable receipt persistence. The pg_cron worker performs
  // lease-backed processing out of band so Shopify receives a 2xx within its 5s budget.
  return reply(200, {
    received: true,
    queued: true,
    duplicate: stored.status !== "PENDING",
    topic,
  });
});

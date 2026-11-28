import "jsr:@supabase/functions-js/edge-runtime.d.ts";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL") ?? "";
const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";

const N8N_INGEST_URL = Deno.env.get("HENVALT_INGEST_WEBHOOK_URL") ?? "https://n8n.henvalt.com/webhook/henvalt/ingest";
const MAX_BODY_BYTES = 1_000_000;
const ALLOWED_TOPICS = new Set(["checkouts/update", "carts/create", "carts/update", "orders/create", "app/uninstalled", "app/scopes_update"]);
type Json = Record<string, unknown>;

function response(status: number, body: Json): Response {
  return new Response(status === 204 ? null : JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json; charset=utf-8", "cache-control": "no-store" },
  });
}
function validShop(raw: string | null): string | null {
  if (!raw) return null;
  const shop = raw.trim().toLowerCase();
  return /^[a-z0-9][a-z0-9-]*\.myshopify\.com$/.test(shop) ? shop : null;
}
function equalSecret(a: string, b: string): boolean {
  const enc = new TextEncoder(), x = enc.encode(a), y = enc.encode(b);
  if (x.length !== y.length) return false;
  let diff = 0;
  for (let i = 0; i < x.length; i++) diff |= x[i] ^ y[i];
  return diff === 0;
}
async function readBody(req: Request): Promise<Json> {
  const declared = Number(req.headers.get("content-length") ?? "0");
  if (declared > MAX_BODY_BYTES) throw new Error("BODY_TOO_LARGE");
  const raw = await req.text();
  if (new TextEncoder().encode(raw).length > MAX_BODY_BYTES) throw new Error("BODY_TOO_LARGE");
  const value = JSON.parse(raw || "{}");
  if (!value || typeof value !== "object" || Array.isArray(value)) throw new Error("INVALID_BODY");
  return value as Json;
}
async function rpc<T>(name: string, args: Json): Promise<T> {
  if (!SUPABASE_URL || !SERVICE_ROLE_KEY) throw new Error("SUPABASE_SERVICE_CONFIG_MISSING");
  const res = await fetch(SUPABASE_URL + "/rest/v1/rpc/" + name, {
    method: "POST",
    headers: {
      apikey: SERVICE_ROLE_KEY, authorization: "Bearer " + SERVICE_ROLE_KEY,
      "content-type": "application/json", "content-profile": "henvalt", "accept-profile": "henvalt",
    },
    body: JSON.stringify(args),
  });
  const text = await res.text();
  if (!res.ok) {
    console.error("Control Plane RPC failed", name, res.status, text.slice(0, 400));
    throw new Error("DATABASE_RPC_" + res.status);
  }
  return (text ? JSON.parse(text) : null) as T;
}
async function connection(shop: string): Promise<{ tenant_id: string; active: boolean; tenant_status: string } | null> {
  return await rpc("control_plane_shop_connection", { p_shop_domain: shop });
}


function validDateOnly(value: string | null): string | null {
  if (!value || !/^\d{4}-\d{2}-\d{2}$/.test(value)) return null;
  const d = new Date(value + "T00:00:00.000Z");
  return Number.isFinite(d.getTime()) && d.toISOString().slice(0,10) === value ? value : null;
}
async function appState(shop: string): Promise<Json> {
  return await rpc<Json>("control_plane_get_app_state", { p_shop_domain: shop });
}
async function updateAppPreferences(shop: string, section: string, patch: Json): Promise<Json> {
  return await rpc<Json>("control_plane_update_app_preferences", {
    p_shop_domain: shop, p_section: section, p_patch: patch,
  });
}

async function shopifyIdentitySuggestion(shop: string): Promise<Json> {
  const token = await rpc<string>("get_shopify_access_token_for_control_plane", { p_shop_domain: shop });
  if (!token || typeof token !== "string" || token.length < 20) throw new Error("SHOPIFY_ADMIN_TOKEN_UNAVAILABLE");
  const query = `query HenvaltMerchantIdentity {
    shop {
      name
      contactEmail
      email
      accountOwner { name }
      billingAddress {
        address1 address2 city company country countryCodeV2
        province provinceCode zip
      }
    }
  }`;
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), 10000);
  try {
    const upstream = await fetch(`https://${shop}/admin/api/2026-10/graphql.json`, {
      method: "POST",
      headers: { "content-type": "application/json", "x-shopify-access-token": token },
      body: JSON.stringify({ query }),
      signal: controller.signal,
    });
    const result = await upstream.json().catch(() => ({})) as Json;
    if (!upstream.ok || Array.isArray(result.errors)) {
      console.error("Shopify identity sync failed", shop, upstream.status);
      throw new Error("SHOPIFY_IDENTITY_SYNC_FAILED");
    }
    const data = result.data as Json | undefined;
    const shopData = data?.shop as Json | undefined;
    const address = (shopData?.billingAddress && typeof shopData.billingAddress === "object"
      ? shopData.billingAddress : {}) as Json;
    const owner = (shopData?.accountOwner && typeof shopData.accountOwner === "object"
      ? shopData.accountOwner : {}) as Json;
    const suggestion: Json = {
      shop_name: typeof shopData?.name === "string" ? shopData.name : "",
      owner_name: typeof owner.name === "string" ? owner.name : "",
      contact_email: typeof shopData?.contactEmail === "string" ? shopData.contactEmail :
        (typeof shopData?.email === "string" ? shopData.email : ""),
      company: typeof address.company === "string" ? address.company : "",
      address_line_1: typeof address.address1 === "string" ? address.address1 : "",
      address_line_2: typeof address.address2 === "string" ? address.address2 : "",
      city: typeof address.city === "string" ? address.city : "",
      region: typeof address.province === "string" ? address.province :
        (typeof address.provinceCode === "string" ? address.provinceCode : ""),
      postal_code: typeof address.zip === "string" ? address.zip : "",
      country_code: typeof address.countryCodeV2 === "string" ? address.countryCodeV2 : "",
      source: "shopify_billing_address",
    };
    const stored = await rpc<Json>("control_plane_store_shopify_identity_suggestion", {
      p_shop_domain: shop, p_suggestion: suggestion,
    });
    if (stored.stored !== true) throw new Error("SHOPIFY_IDENTITY_SUGGESTION_NOT_STORED");
    return { synced: true, requiresMerchantConfirmation: true, suggestion };
  } finally {
    clearTimeout(timer);
  }
}

async function dashboardSummary(shop: string, fromRaw: string | null, toRaw: string | null): Promise<Json> {
  const today = new Date().toISOString().slice(0,10);
  const from = validDateOnly(fromRaw) ?? validDateOnly(new Date(Date.now()-29*86400000).toISOString().slice(0,10));
  const to = validDateOnly(toRaw) ?? today;
  if (!from || !to || to < from) throw new Error("INVALID_DATE_RANGE");
  return await rpc<Json>("control_plane_dashboard_summary", {
    p_shop_domain: shop,
    p_from: from + "T00:00:00.000Z",
    p_to: to + "T00:00:00.000Z",
  });
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return response(204, {});
  if (req.method !== "GET" && req.method !== "POST" && req.method !== "PUT") return response(405, { error: "method_not_allowed" });
  const authorization = req.headers.get("authorization") ?? "";
  const suppliedToken = authorization.startsWith("Bearer ") ? authorization.slice(7).trim() : "";
  let authorized = false;
  if (suppliedToken) {
    try {
      authorized = await rpc<boolean>("control_plane_verify_api_token", { p_candidate: suppliedToken });
    } catch (error) {
      console.error("Control Plane Vault token verification unavailable", error instanceof Error ? error.message : "unknown_error");
      return response(503, { error: "control_plane_auth_unavailable" });
    }
  }
  if (!authorized) return response(401, { error: "unauthorized" });
  const shop = validShop(req.headers.get("x-henvalt-shop"));
  if (!shop) return response(400, { error: "invalid_shop_domain" });
  const url = new URL(req.url);
  // Normalize both full Supabase paths and paths stripped by the Edge Runtime.
  let path = url.pathname;
  const marker = "/functions/v1/henvalt-control-plane";
  if (path.includes(marker)) path = path.slice(path.indexOf(marker) + marker.length);
  else {
    const routeStart = path.lastIndexOf("/v1/");
    if (routeStart >= 0) path = path.slice(routeStart);
  }
  while (path.length > 1 && path.endsWith("/")) path = path.slice(0, -1);

  try {
    if (req.method === "GET" && path === "/v1/tenants/me") {
      const conn = await connection(shop);
      return response(200, { linked: Boolean(conn?.active && conn.tenant_status === "ACTIVE"), shopName: conn ? shop : null });
    }
    if (req.method === "POST" && path === "/v1/tenants/connect") {
      const body = await readBody(req);
      if (validShop(typeof body.shop === "string" ? body.shop : null) !== shop) return response(400, { error: "shop_header_body_mismatch" });
      const result = await rpc<Json>("control_plane_connect_shop", { p_shop_domain: shop });
      return response(200, { linked: true, shopName: shop, connectionId: result.connection_id });
    }
    if (req.method === "GET" && path === "/v1/billing") {
      return response(200, await rpc<Json>("control_plane_billing_summary", { p_shop_domain: shop }));
    }
    if (req.method === "POST" && path === "/v1/billing/sync") {
      const body = await readBody(req);
      if (validShop(typeof body.shop === "string" ? body.shop : null) !== shop) return response(400, { error: "shop_header_body_mismatch" });
      if (!body.account || typeof body.account !== "object" || Array.isArray(body.account)) return response(400, { error: "billing_account_required" });
      return response(200, await rpc<Json>("control_plane_sync_billing_account", { p_shop_domain: shop, p_account: body.account as Json }));
    }
    if (req.method === "POST" && path === "/v1/billing/status") {
      const body = await readBody(req);
      if (validShop(typeof body.shop === "string" ? body.shop : null) !== shop) return response(400, { error: "shop_header_body_mismatch" });
      const subscriptionId = typeof body.subscriptionId === "string" ? body.subscriptionId.trim() : "";
      const status = typeof body.status === "string" ? body.status.toUpperCase() : "";
      if (!subscriptionId || subscriptionId.length > 255) return response(400, { error: "subscription_id_required" });
      return response(200, await rpc<Json>("control_plane_set_billing_status", { p_shop_domain: shop, p_subscription_id: subscriptionId, p_status: status }));
    }
    if (req.method === "POST" && path === "/v1/billing/usage/claim") {
      const body = await readBody(req);
      if (validShop(typeof body.shop === "string" ? body.shop : null) !== shop) return response(400, { error: "shop_header_body_mismatch" });
      return response(200, await rpc<Json>("control_plane_claim_billing_usage", { p_shop_domain: shop }));
    }
    if (req.method === "POST" && path === "/v1/billing/usage/result") {
      const body = await readBody(req);
      if (validShop(typeof body.shop === "string" ? body.shop : null) !== shop) return response(400, { error: "shop_header_body_mismatch" });
      const chargeId = typeof body.chargeId === "string" ? body.chargeId : "";
      if (!/^[0-9a-f-]{36}$/i.test(chargeId)) return response(400, { error: "invalid_charge_id" });
      const success = body.success === true;
      const providerId = typeof body.providerUsageRecordId === "string" ? body.providerUsageRecordId : null;
      const errorCode = typeof body.errorCode === "string" ? body.errorCode : null;
      const errorMessage = typeof body.errorMessage === "string" ? body.errorMessage : null;
      return response(200, await rpc<Json>("control_plane_record_billing_usage_result", {
        p_shop_domain: shop, p_charge_id: chargeId, p_success: success,
        p_provider_usage_record_id: providerId, p_error_code: errorCode, p_error_message: errorMessage,
      }));
    }

    if (req.method === "GET" && path === "/v1/dashboard") {
      const summary = await dashboardSummary(shop, url.searchParams.get("from"), url.searchParams.get("to"));
      if (summary.linked !== true) return response(404, { error: "shop_connection_not_found" });
      return response(200, { shopName: summary.shopName, metrics: summary.metrics, activity: summary.activity, message: null });
    }
    if (req.method === "GET" && path === "/v1/analytics") {
      const summary = await dashboardSummary(shop, url.searchParams.get("from"), url.searchParams.get("to"));
      if (summary.linked !== true) return response(404, { error: "shop_connection_not_found" });
      return response(200, { currency: summary.currency ?? "USD", totals: summary.totals, byEvent: summary.byEvent ?? [] });
    }
    if (req.method === "GET" && path === "/v1/recovery") {
      const state = await appState(shop);
      if (state.linked !== true) return response(404, { error: "shop_connection_not_found" });
      const recovery = (state.recovery && typeof state.recovery === "object" ? state.recovery : {}) as Json;
      const flows = Array.isArray(recovery.flows) ? recovery.flows : [];
      const configured = (state.settings as Json | undefined)?.emailConfigured === true;
      return response(200, { flows, channels: [{ id: "email", label: "Email", available: configured }] });
    }
    if (req.method === "PUT" && path === "/v1/recovery") {
      const body = await readBody(req);
      if (!Array.isArray(body.flows)) return response(400, { error: "flows_required" });
      const result = await updateAppPreferences(shop, "recovery", { flows: body.flows });
      return response(200, result);
    }
    if (req.method === "GET" && path === "/v1/campaign") {
      const state = await appState(shop);
      if (state.linked !== true) return response(404, { error: "shop_connection_not_found" });
      return response(200, { settings: state.campaign ?? { emailEnabled:false, delayMinutes:60, subject:"", message:"", brandName:state.tenantName ?? "", logoUrl:"", couponType:"none", couponValue:0, couponExpiresDays:7 } });
    }
    if (req.method === "PUT" && path === "/v1/campaign") {
      const body = await readBody(req);
      if (!body.settings || typeof body.settings !== "object" || Array.isArray(body.settings)) return response(400, { error: "settings_required" });
      const result = await updateAppPreferences(shop, "campaign", { settings: body.settings as Json });
      return response(200, result);
    }

    if (req.method === "GET" && path === "/v1/sender-profile") {
      const profile = await rpc<Json>("control_plane_get_sender_profile", { p_shop_domain: shop });
      if (profile.linked !== true) return response(404, { error: "shop_connection_not_found" });
      return response(200, profile);
    }
    if (req.method === "POST" && path === "/v1/sender-profile/sync") {
      const synced = await shopifyIdentitySuggestion(shop);
      return response(200, synced);
    }
    if (req.method === "PUT" && path === "/v1/sender-profile") {
      const body = await readBody(req);
      const profile = body.profile && typeof body.profile === "object" && !Array.isArray(body.profile)
        ? body.profile as Json : body;
      const result = await rpc<Json>("control_plane_update_sender_profile", {
        p_shop_domain: shop, p_profile: profile,
      });
      if (result.updated !== true) return response(409, { error: String(result.reason ?? "sender_profile_not_updated") });
      return response(200, result);
    }

    if (req.method === "GET" && path === "/v1/settings") {
      const state = await appState(shop);
      if (state.linked !== true) return response(404, { error: "shop_connection_not_found" });
      const settings = (state.settings && typeof state.settings === "object" ? state.settings : {}) as Json;
      const billing = (state.billing && typeof state.billing === "object" ? state.billing : {}) as Json;
      return response(200, {
        shopName: state.shopName ?? shop,
        email: settings.email ?? null,
        plan: billing.plan ?? null,
        currency: state.currency ?? billing.currency ?? "USD",
        timezone: settings.timezone ?? "UTC",
        brandName: settings.brandName ?? state.tenantName ?? "",
        logoUrl: settings.logoUrl ?? "",
        emailConfigured: settings.emailConfigured === true,
        recoveryEnabled: settings.recoveryEnabled === true,
      });
    }
    if (req.method === "PUT" && path === "/v1/settings") {
      const body = await readBody(req);
      const patch: Json = {};
      for (const key of ["brandName", "logoUrl", "recoveryEnabled"]) {
        if (Object.prototype.hasOwnProperty.call(body, key)) patch[key] = body[key];
      }
      if (Object.keys(patch).length === 0) return response(400, { error: "settings_patch_required" });
      const result = await updateAppPreferences(shop, "settings", patch);
      return response(200, result);
    }

    if (req.method === "POST" && path === "/v1/webhooks/shopify") {
      const body = await readBody(req);
      const topic = typeof body.topic === "string" ? body.topic.toLowerCase() : "";
      const sourceEventId = typeof body.sourceEventId === "string" ? body.sourceEventId.trim() : "";
      const idempotencyKey = typeof body.idempotencyKey === "string" ? body.idempotencyKey.trim() : "";
      const rawBody = typeof body.rawBody === "string" ? body.rawBody : "";
      const headers = body.headers && typeof body.headers === "object" && !Array.isArray(body.headers) ? body.headers as Record<string, unknown> : {};
      const headerValue = (name: string) => typeof headers[name] === "string" ? String(headers[name]) : "";
      const originalShop = validShop(headerValue("x-shopify-shop-domain"));
      const originalTopic = headerValue("x-shopify-topic").toLowerCase();
      const originalHmac = headerValue("x-shopify-hmac-sha256");
      if (!ALLOWED_TOPICS.has(topic)) return response(400, { error: "unsupported_topic" });
      if (!sourceEventId || sourceEventId.length > 255 || !idempotencyKey || idempotencyKey.length > 512) return response(400, { error: "invalid_event_identity" });
      if (!rawBody || !originalShop || originalShop !== shop || originalTopic !== topic || !originalHmac) return response(400, { error: "missing_or_mismatched_original_shopify_request" });
      if (new TextEncoder().encode(rawBody).length > MAX_BODY_BYTES) return response(413, { error: "body_too_large" });
      try { JSON.parse(rawBody); } catch { return response(400, { error: "invalid_original_json_body" }); }
      const conn = await connection(shop);
      if (!conn || conn.tenant_status !== "ACTIVE" || (!conn.active && topic !== "app/uninstalled")) return response(404, { error: "active_shop_connection_not_found" });
      const forwarded = new Headers({ "content-type": headerValue("content-type") || "application/json" });
      for (const name of ["x-shopify-shop-domain", "x-shopify-topic", "x-shopify-webhook-id", "x-shopify-event-id", "x-shopify-api-version", "x-shopify-triggered-at", "x-shopify-hmac-sha256"]) {
        const value = headerValue(name);
        if (value) forwarded.set(name, value);
      }
      const controller = new AbortController();
      const timer = setTimeout(() => controller.abort(), 8000);
      try {
        const upstream = await fetch(N8N_INGEST_URL, { method: "POST", headers: forwarded, body: rawBody, signal: controller.signal });
        const upstreamText = await upstream.text();
        if (!upstream.ok) {
          console.error("HENVALT_INGEST rejected forwarded Shopify webhook", upstream.status, shop, topic);
          return response(503, { error: "ingest_unavailable" });
        }
        let result: Record<string, unknown> = {};
        try { result = JSON.parse(upstreamText) as Record<string, unknown>; } catch { /* upstream status remains authoritative */ }
        return response(200, {
          webhookId: typeof result.webhook_id === "string" ? result.webhook_id : sourceEventId,
          duplicate: ["duplicate", "replay_accepted", "already_processing"].includes(String(result.status ?? "")),
          ingestStatus: result.status ?? "accepted",
        });
      } finally { clearTimeout(timer); }
    }
    if (req.method === "POST" && path === "/v1/tenants/disconnect") {
      const body = await readBody(req);
      if (validShop(typeof body.shop === "string" ? body.shop : null) !== shop) return response(400, { error: "shop_header_body_mismatch" });
      if (!(await connection(shop))) return response(404, { error: "shop_connection_not_found" });
      const result = await rpc<Json>("control_plane_disconnect_shop", { p_shop_domain: shop, p_webhook_event_id: null, p_correlation_id: crypto.randomUUID() });
      return response(200, { disconnected: true, alreadyDisconnected: result.already_disconnected === true });
    }
    return response(404, { error: "route_not_found" });
  } catch (error) {
    const message = error instanceof Error ? error.message : "unknown_error";
    if (message === "BODY_TOO_LARGE") return response(413, { error: "body_too_large" });
    if (message === "INVALID_BODY" || message === "Unexpected end of JSON input") return response(400, { error: "invalid_json_body" });
    if (message === "INVALID_DATE_RANGE" || message === "DATABASE_RPC_400") return response(400, { error: "invalid_request" });
    console.error("Control Plane request failed", path, message);
    return response(503, { error: "control_plane_unavailable" });
  }
});

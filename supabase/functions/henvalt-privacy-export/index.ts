// Candidate replacement for deployed Supabase Edge Function henvalt-privacy-export.
// Preserves owner/admin authentication and adds explicit client acknowledgement after the response body is received.
// Source SHA-256: 708f0d953874f9e4896f433d950d57b823b56cbb33e30e8c0b1f966ec1212d97
// This is a merchant-owner authenticated download endpoint; do not treat it as automatic Shopify delivery.
import "jsr:@supabase/functions-js/edge-runtime.d.ts";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL") ?? "";
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
const ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY") ?? "";
const headers = {
  "access-control-allow-origin": "https://henvalt-dashboard.pages.dev",
  "access-control-allow-headers": "authorization, apikey, content-type, x-client-info",
  "access-control-allow-methods": "GET, POST, OPTIONS",
  "access-control-expose-headers": "content-disposition, x-henvalt-delivery-ack-token",
  "cache-control": "no-store",
};
const reply = (status: number, body: unknown, extra: Record<string, string> = {}) =>
  new Response(JSON.stringify(body), { status, headers: { ...headers, "content-type": "application/json; charset=utf-8", ...extra } });

async function rest(path: string, method = "GET", body?: unknown) {
  return fetch(SUPABASE_URL + "/rest/v1/" + path, {
    method,
    headers: {
      apikey: SERVICE_KEY,
      authorization: "Bearer " + SERVICE_KEY,
      "content-type": "application/json",
      "accept-profile": "henvalt",
      "content-profile": "henvalt",
      ...(body === undefined ? {} : { prefer: "return=minimal" }),
    },
    ...(body === undefined ? {} : { body: JSON.stringify(body) }),
  });
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response(null, { status: 204, headers });
  if (req.method !== "GET" && req.method !== "POST") return reply(405, { error: "method_not_allowed" });
  if (!SUPABASE_URL || !SERVICE_KEY || !ANON_KEY) return reply(503, { error: "privacy_export_not_configured" });

  try {
    const token = (req.headers.get("authorization") ?? "").replace(/^Bearer\s+/i, "").trim();
    if (!token) return reply(401, { error: "sign_in_required" });

    // Validate the access token with Supabase Auth; never trust decoded JWT claims.
    const auth = await fetch(SUPABASE_URL + "/auth/v1/user", {
      headers: { apikey: ANON_KEY, authorization: "Bearer " + token },
    });
    if (!auth.ok) return reply(401, { error: "invalid_session" });
    const user = await auth.json();
    if (typeof user.id !== "string") return reply(401, { error: "invalid_session" });

    // Match the dashboard's single-tenant rule and require an owner/admin membership.
    const memberships = await rest(
      "tenant_memberships?select=tenant_id,role&user_id=eq." + encodeURIComponent(user.id) +
      "&role=in.(OWNER,ADMIN)&limit=2",
    );
    if (!memberships.ok) return reply(503, { error: "membership_lookup_failed" });
    const rows = await memberships.json();
    if (!Array.isArray(rows) || rows.length !== 1 || !rows[0]?.tenant_id) {
      return reply(403, { error: "workspace_owner_required" });
    }
    const tenantId = String(rows[0].tenant_id);
    if (req.method === "POST") {
      const body = await req.json().catch(() => null);
      const requestId = typeof body?.request_id === "string" ? body.request_id : "";
      const ackToken = typeof body?.ack_token === "string" ? body.ack_token : "";
      if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(requestId)
        || !/^[a-f0-9]{64}$/.test(ackToken)) {
        return reply(400, { error: "invalid_export_acknowledgement" });
      }
      const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(ackToken));
      const tokenHash = Array.from(new Uint8Array(digest), b => b.toString(16).padStart(2, "0")).join("");
      const acknowledged = await rest("rpc/acknowledge_shopify_privacy_export_download", "POST", {
        p_request_id: requestId,
        p_tenant_id: tenantId,
        p_token_hash: tokenHash,
      });
      if (!acknowledged.ok) return reply(503, { error: "export_acknowledgement_failed" });
      const accepted = await acknowledged.json().catch(() => false);
      if (accepted !== true) return reply(409, { error: "export_acknowledgement_expired_or_invalid" });
      return reply(200, { acknowledged: true, request_id: requestId });
    }

    // Also expire old export bundles when an owner opens the privacy page or downloads an export.
    const purge = await rest("rpc/purge_expired_shopify_privacy_exports", "POST", {});
    if (!purge.ok) console.error("Expired privacy export cleanup failed", purge.status);
    const u = new URL(req.url);
    const requestId = u.searchParams.get("request_id");

    if (!requestId) {
      const list = await rest(
        "shopify_privacy_requests?select=id,shop_domain,request_id,received_at,result_expires_at,result_download_started_at,result_client_acknowledged_at,status,last_error" +
        "&tenant_id=eq." + encodeURIComponent(tenantId) +
        "&topic=eq.customers/data_request&status=eq.REVIEW_REQUIRED" +
        "&order=received_at.desc&limit=50",
      );
      if (!list.ok) return reply(503, { error: "privacy_request_list_failed" });
      return reply(200, { requests: await list.json() });
    }

    if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(requestId)) {
      return reply(400, { error: "invalid_request_id" });
    }
    const lookup = await rest(
      "shopify_privacy_requests?select=id,shop_domain,request_id,result_payload,result_expires_at" +
      "&id=eq." + encodeURIComponent(requestId) +
      "&tenant_id=eq." + encodeURIComponent(tenantId) +
      "&topic=eq.customers/data_request&status=eq.REVIEW_REQUIRED" +
      "&result_payload=not.is.null&result_expires_at=gt." + encodeURIComponent(new Date().toISOString()) +
      "&limit=1",
    );
    if (!lookup.ok) return reply(503, { error: "privacy_export_lookup_failed" });
    const found = await lookup.json();
    const record = Array.isArray(found) ? found[0] : null;
    if (!record?.result_payload) return reply(404, { error: "export_not_found_or_expired" });

    const randomBytes = crypto.getRandomValues(new Uint8Array(32));
    const ackToken = Array.from(randomBytes, b => b.toString(16).padStart(2, "0")).join("");
    const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(ackToken));
    const tokenHash = Array.from(new Uint8Array(digest), b => b.toString(16).padStart(2, "0")).join("");
    const ackExpiresAt = new Date(Date.now() + 5 * 60 * 1000).toISOString();
    const started = await rest(
      "shopify_privacy_requests?id=eq." + encodeURIComponent(requestId) +
      "&tenant_id=eq." + encodeURIComponent(tenantId) +
      "&topic=eq.customers/data_request&status=eq.REVIEW_REQUIRED",
      "PATCH",
      {
        result_download_started_at: new Date().toISOString(),
        result_delivery_ack_token_hash: tokenHash,
        result_delivery_ack_expires_at: ackExpiresAt,
      },
    );
    if (!started.ok) return reply(503, { error: "export_download_start_failed" });

    const filename = "henvalt-customer-data-" + String(record.request_id || requestId).replace(/[^a-zA-Z0-9_-]/g, "_") + ".json";
    return new Response(JSON.stringify(record.result_payload, null, 2), {
      status: 200,
      headers: {
        ...headers,
        "content-type": "application/json; charset=utf-8",
        "content-disposition": 'attachment; filename="' + filename + '"',
        "x-content-type-options": "nosniff",
        "x-henvalt-delivery-ack-token": ackToken,
      },
    });
  } catch (error) {
    console.error("Privacy export endpoint failed", error);
    return reply(500, { error: "privacy_export_unavailable" });
  }
});

import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { isDateOnly, isValidDateRange } from "../_shared/date-range-v2.mjs";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL") ?? "";
const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
const ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY") ?? "";
const cors = {
  "access-control-allow-origin": "*",
  "access-control-allow-headers": "authorization, apikey, content-type, x-client-info",
  "access-control-allow-methods": "GET, OPTIONS",
  "content-type": "application/json; charset=utf-8",
  "cache-control": "no-store",
};
const reply = (status: number, body: unknown) =>
  new Response(JSON.stringify(body), { status, headers: cors });

async function rest(path: string, method = "GET", body?: unknown) {
  const response = await fetch(SUPABASE_URL + "/rest/v1/" + path, {
    method,
    headers: {
      apikey: SERVICE_ROLE_KEY,
      authorization: "Bearer " + SERVICE_ROLE_KEY,
      "content-type": "application/json",
      "accept-profile": "henvalt",
      "content-profile": "henvalt",
      ...(body === undefined ? {} : { Prefer: "return=representation" }),
    },
    ...(body === undefined ? {} : { body: JSON.stringify(body) }),
    signal: AbortSignal.timeout(10000),
  });
  if (!response.ok) throw new Error("DATABASE_LOOKUP_FAILED");
  return await response.json();
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response(null, { status: 204, headers: cors });
  if (req.method !== "GET") return reply(405, { error: "method_not_allowed" });
  try {
    if (!SUPABASE_URL || !SERVICE_ROLE_KEY || !ANON_KEY) {
      return reply(503, { error: "dashboard_not_configured" });
    }
    const token = (req.headers.get("authorization") ?? "").replace(/^Bearer\s+/i, "").trim();
    if (!token) return reply(401, { error: "sign_in_required" });

    // Validate the Supabase access token against Auth; do not trust decoded JWT claims.
    const authResponse = await fetch(SUPABASE_URL + "/auth/v1/user", {
      headers: { apikey: ANON_KEY, authorization: "Bearer " + token },
      signal: AbortSignal.timeout(10000),
    });
    if (!authResponse.ok) return reply(401, { error: "invalid_session" });
    const user = await authResponse.json();
    if (typeof user.id !== "string") return reply(401, { error: "invalid_session" });

    const membership = await rest("tenant_memberships?select=tenant_id&user_id=eq." +
      encodeURIComponent(user.id) + "&limit=2");
    if (!Array.isArray(membership) || membership.length !== 1 || !membership[0].tenant_id) {
      return reply(403, { error: "one_active_tenant_membership_required" });
    }
    const tenantId = membership[0].tenant_id;
    const u = new URL(req.url);

    // Only show stores installed through an active, owner-controlled V2 app
    // identity. Legacy rows marked active but missing app/token lineage must
    // not appear as selectable V2 dashboard stores.
    const appRows = await rest("shopify_app_registry?select=app_key&lifecycle_status=eq.active&limit=100");
    if (!Array.isArray(appRows)) throw new Error("APP_REGISTRY_LOOKUP_INVALID");
    const appKeyPattern = /^[a-z][a-z0-9_-]{2,63}$/;
    const activeAppKeys = appRows
      .map((item: any) => item?.app_key)
      .filter((key: unknown): key is string => typeof key === "string" && appKeyPattern.test(key));
    if (activeAppKeys.length === 0) {
      return reply(409, { error: "owner_controlled_shop_connection_required" });
    }

    const appKeyFilter = "in.(" + activeAppKeys.map(key => encodeURIComponent(key)).join(",") + ")";
    const connections = await rest("shopify_connections?select=id,shop_domain,active&tenant_id=eq." +
      encodeURIComponent(tenantId) + "&active=eq.true&app_key=" + appKeyFilter +
      "&shopify_shop_id=not.is.null&access_token_secret_ref=not.is.null" +
      "&refresh_token_secret_ref=not.is.null&reauth_required_at=is.null" +
      "&tenants!inner(status)&tenants.status=eq.ACTIVE&order=shop_domain.asc&limit=100");
    if (!Array.isArray(connections) || connections.length === 0) {
      return reply(409, { error: "owner_controlled_shop_connection_required" });
    }
    const requestedConnectionId = u.searchParams.get("shopify_connection_id");
    let selectedConnection: any = null;
    if (requestedConnectionId !== null) {
      if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(requestedConnectionId)) {
        return reply(400, { error: "invalid_store_selection" });
      }
      selectedConnection = connections.find((item: any) => item.id === requestedConnectionId) ?? null;
      if (!selectedConnection) return reply(404, { error: "store_not_available" });
    } else if (connections.length === 1) {
      selectedConnection = connections[0];
    } else {
      return reply(409, {
        error: "store_selection_required",
        stores: connections.map((item: any) => ({ id: item.id, shop_domain: item.shop_domain })),
      });
    }
    if (typeof selectedConnection.shop_domain !== "string") {
      return reply(409, { error: "shop_not_connected" });
    }
    const today = new Date().toISOString().slice(0, 10);
    const from = (isDateOnly(u.searchParams.get("from")) ? u.searchParams.get("from") : null) ??
      new Date(Date.now() - 29 * 86400000).toISOString().slice(0, 10);
    const to = (isDateOnly(u.searchParams.get("to")) ? u.searchParams.get("to") : null) ?? today;
    if (!isValidDateRange(from, to, 366)) {
      return reply(400, { error: "invalid_date_range" });
    }

    const summaryResponse = await fetch(SUPABASE_URL + "/rest/v1/rpc/control_plane_dashboard_summary_v2", {
      method: "POST",
      headers: {
        apikey: SERVICE_ROLE_KEY,
        authorization: "Bearer " + SERVICE_ROLE_KEY,
        "content-type": "application/json",
        "accept-profile": "henvalt",
        "content-profile": "henvalt",
      },
      body: JSON.stringify({
        p_shopify_connection_id: selectedConnection.id,
        p_from: from + "T00:00:00.000Z",
        p_to: to + "T00:00:00.000Z",
      }),
      signal: AbortSignal.timeout(12000),
    });
    if (!summaryResponse.ok) throw new Error("SUMMARY_QUERY_FAILED");
    const summary = await summaryResponse.json();
    if (!summary || summary.linked !== true) return reply(409, { error: "shop_not_connected" });
    return reply(200, {
      ...summary,
      selectedStoreId: selectedConnection.id,
      stores: connections.map((item: any) => ({ id: item.id, shop_domain: item.shop_domain })),
      range: { from, to },
      generatedAt: new Date().toISOString(),
    });
  } catch {
    return reply(500, { error: "dashboard_unavailable" });
  }
});
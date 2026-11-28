import "jsr:@supabase/functions-js/edge-runtime.d.ts";

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
    redirect: "error",
    headers: {
      apikey: SERVICE_ROLE_KEY,
      authorization: "Bearer " + SERVICE_ROLE_KEY,
      "content-type": "application/json",
      "accept-profile": "henvalt",
      "content-profile": "henvalt",
      ...(body === undefined ? {} : { Prefer: "return=representation" }),
    },
    ...(body === undefined ? {} : { body: JSON.stringify(body) }),
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
      redirect: "error",
      headers: { apikey: ANON_KEY, authorization: "Bearer " + token },
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
    const connections = await rest("shopify_connections?select=shop_domain,active,tenants!inner(status)&tenant_id=eq." +
      encodeURIComponent(tenantId) + "&active=eq.true&tenants.status=eq.ACTIVE&limit=2");
    if (!Array.isArray(connections) || connections.length !== 1 ||
        typeof connections[0].shop_domain !== "string") {
      return reply(409, { error: "active_shop_connection_required" });
    }

    const u = new URL(req.url);
    const validDate = (v: string | null) =>
      v && /^\d{4}-\d{2}-\d{2}$/.test(v) && !Number.isNaN(Date.parse(v)) ? v : null;
    const today = new Date().toISOString().slice(0, 10);
    const from = validDate(u.searchParams.get("from")) ??
      new Date(Date.now() - 29 * 86400000).toISOString().slice(0, 10);
    const to = validDate(u.searchParams.get("to")) ?? today;
    if (to < from || Date.parse(to) - Date.parse(from) > 366 * 86400000) {
      return reply(400, { error: "invalid_date_range" });
    }
    const requestedGranularity = u.searchParams.get("granularity");
    const granularity = ["day", "week", "month"].includes(requestedGranularity ?? "")
      ? requestedGranularity!
      : "day";

    const summaryResponse = await fetch(SUPABASE_URL + "/rest/v1/rpc/control_plane_dashboard_summary", {
      method: "POST",
      redirect: "error",
      headers: {
        apikey: SERVICE_ROLE_KEY,
        authorization: "Bearer " + SERVICE_ROLE_KEY,
        "content-type": "application/json",
        "accept-profile": "henvalt",
        "content-profile": "henvalt",
      },
      body: JSON.stringify({
        p_shop_domain: connections[0].shop_domain,
        p_from: from + "T00:00:00.000Z",
        p_to: to + "T00:00:00.000Z",
      }),
    });
    if (!summaryResponse.ok) throw new Error("SUMMARY_QUERY_FAILED");
    const summary = await summaryResponse.json();
    if (!summary || summary.linked !== true) return reply(409, { error: "shop_not_connected" });

    const seriesResponse = await fetch(SUPABASE_URL + "/rest/v1/rpc/control_plane_revenue_series", {
      method: "POST",
      redirect: "error",
      headers: {
        apikey: SERVICE_ROLE_KEY,
        authorization: "Bearer " + SERVICE_ROLE_KEY,
        "content-type": "application/json",
        "accept-profile": "henvalt",
        "content-profile": "henvalt",
      },
      body: JSON.stringify({
        p_shop_domain: connections[0].shop_domain,
        p_from: from + "T00:00:00.000Z",
        p_to: to + "T00:00:00.000Z",
        p_granularity: granularity,
      }),
    });
    if (!seriesResponse.ok) throw new Error("REVENUE_SERIES_QUERY_FAILED");
    const revenue = await seriesResponse.json();

    // Preserve the deployed v4 response contract while returning the corrected
    // confirmed-attribution summary and range-aware revenue series.
    const toExclusive = new Date(Date.parse(to + "T00:00:00.000Z") + 86400000).toISOString();
    const ledgerQuery = new URLSearchParams({
      select: "id,order_id,amount,currency,created_at,attribution_confidence,billable,billing_status,order:orders!revenue_ledger_order_id_fkey(shopify_order_id,order_number,total_value),attribution:order_attributions!revenue_ledger_attribution_id_fkey(attribution_method,attribution_confidence),billing:billing_measurements!billing_measurements_ledger_entry_id_fkey(henvalt_percentage,henvalt_fee,status)",
      tenant_id: "eq." + tenantId,
      entry_type: "eq.RECOVERY",
      attribution_confidence: "eq.CONFIRMED",
      created_at: "gte." + from + "T00:00:00.000Z",
      and: "(created_at.lt." + toExclusive + ")",
      order: "created_at.desc",
      limit: "50",
    });
    const ledger = await rest("revenue_ledger?" + ledgerQuery.toString());
    if (!Array.isArray(ledger)) throw new Error("REVENUE_LEDGER_INVALID_RESPONSE");

    return reply(200, {
      ...summary,
      ledger,
      revenueSeries: Array.isArray(revenue?.series) ? revenue.series : [],
      revenueComparison: {
        currentRevenue: revenue?.current_revenue ?? summary.metrics?.revenueRecovered ?? 0,
        previousRevenue: revenue?.previous_revenue ?? 0,
        changePercent: revenue?.change_percent ?? null,
        previousFrom: revenue?.previous_from ?? null,
        previousTo: revenue?.previous_to ?? null,
      },
      range: { from, to, granularity },
      generatedAt: new Date().toISOString(),
    });
  } catch {
    return reply(500, { error: "dashboard_unavailable" });
  }
});
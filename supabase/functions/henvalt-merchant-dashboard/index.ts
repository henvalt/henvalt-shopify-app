import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { resolveDashboardRange } from "./validation.ts";

type DashboardHandlerOptions = {
  supabaseUrl: string;
  serviceRoleKey: string;
  anonKey: string;
  fetchImpl?: typeof fetch;
  now?: () => Date;
};

const cors = {
  "access-control-allow-origin": "*",
  "access-control-allow-headers": "authorization, apikey, content-type, x-client-info",
  "access-control-allow-methods": "GET, OPTIONS",
  "content-type": "application/json; charset=utf-8",
  "cache-control": "no-store",
};
const reply = (status: number, body: unknown) =>
  new Response(JSON.stringify(body), { status, headers: cors });

export function createDashboardHandler(options: DashboardHandlerOptions) {
  const { supabaseUrl, serviceRoleKey, anonKey } = options;
  const fetchImpl = options.fetchImpl ?? fetch;
  const now = options.now ?? (() => new Date());

  return async (req: Request): Promise<Response> => {
    if (req.method === "OPTIONS") return new Response(null, { status: 204, headers: cors });
    if (req.method !== "GET") return reply(405, { error: "method_not_allowed" });
    try {
      if (!supabaseUrl || !serviceRoleKey || !anonKey) {
        return reply(503, { error: "dashboard_not_configured" });
      }
      const token = (req.headers.get("authorization") ?? "").replace(/^Bearer\\s+/i, "").trim();
      if (!token) return reply(401, { error: "sign_in_required" });

      // Validate the Supabase access token against Auth; never trust decoded JWT claims.
      const authResponse = await fetchImpl(supabaseUrl + "/auth/v1/user", {
        headers: { apikey: anonKey, authorization: "Bearer " + token },
      });
      if (!authResponse.ok) return reply(401, { error: "invalid_session" });
      const user = await authResponse.json();
      if (typeof user.id !== "string") return reply(401, { error: "invalid_session" });

      const membershipResponse = await fetchImpl(
        supabaseUrl + "/rest/v1/tenant_memberships?select=tenant_id&user_id=eq." +
          encodeURIComponent(user.id) + "&limit=2",
        { headers: { apikey: serviceRoleKey, authorization: "Bearer " + serviceRoleKey,
          "accept-profile": "henvalt" } },
      );
      if (!membershipResponse.ok) throw new Error("MEMBERSHIP_LOOKUP_FAILED");
      const membership = await membershipResponse.json();
      if (!Array.isArray(membership) || membership.length !== 1 || !membership[0].tenant_id) {
        return reply(403, { error: "one_active_tenant_membership_required" });
      }
      const tenantId = membership[0].tenant_id;

      const connectionResponse = await fetchImpl(
        supabaseUrl + "/rest/v1/shopify_connections?select=shop_domain,active,tenants!inner(status)&tenant_id=eq." +
          encodeURIComponent(tenantId) + "&active=eq.true&tenants.status=eq.ACTIVE&limit=2",
        { headers: { apikey: serviceRoleKey, authorization: "Bearer " + serviceRoleKey,
          "accept-profile": "henvalt" } },
      );
      if (!connectionResponse.ok) throw new Error("CONNECTION_LOOKUP_FAILED");
      const connections = await connectionResponse.json();
      if (!Array.isArray(connections) || connections.length !== 1 ||
          typeof connections[0].shop_domain !== "string") {
        return reply(409, { error: "active_shop_connection_required" });
      }

      const u = new URL(req.url);
      const today = now().toISOString().slice(0, 10);
      const defaultFrom = new Date(Date.parse(today + "T00:00:00.000Z") - 29 * 86400000)
        .toISOString().slice(0, 10);
      const range = resolveDashboardRange(
        u.searchParams.get("from"),
        u.searchParams.get("to"),
        u.searchParams.get("granularity"),
        today,
        defaultFrom,
      );
      if (!range.ok) return reply(400, { error: range.error });
      const { from, to, granularity } = range;

      const rpcHeaders = {
        apikey: serviceRoleKey,
        authorization: "Bearer " + serviceRoleKey,
        "content-type": "application/json",
        "accept-profile": "henvalt",
        "content-profile": "henvalt",
      };
      const rpcBody = {
        p_shop_domain: connections[0].shop_domain,
        p_from: from + "T00:00:00.000Z",
        p_to: to + "T00:00:00.000Z",
      };
      const summaryResponse = await fetchImpl(supabaseUrl + "/rest/v1/rpc/control_plane_dashboard_summary", {
        method: "POST", headers: rpcHeaders, body: JSON.stringify(rpcBody),
      });
      if (!summaryResponse.ok) throw new Error("SUMMARY_QUERY_FAILED");
      const summary = await summaryResponse.json();
      if (!summary || summary.linked !== true) return reply(409, { error: "shop_not_connected" });

      const seriesResponse = await fetchImpl(supabaseUrl + "/rest/v1/rpc/control_plane_revenue_series", {
        method: "POST",
        headers: rpcHeaders,
        body: JSON.stringify({ ...rpcBody, p_granularity: granularity }),
      });
      if (!seriesResponse.ok) throw new Error("REVENUE_SERIES_QUERY_FAILED");
      const revenue = await seriesResponse.json();

      const toExclusive = new Date(Date.parse(to + "T00:00:00.000Z") + 86400000).toISOString();
      const ledgerUrl = new URL(supabaseUrl + "/rest/v1/revenue_ledger");
      ledgerUrl.search = new URLSearchParams({
        select: "id,order_id,amount,currency,created_at,attribution_confidence,billable,billing_status,order:orders!revenue_ledger_order_id_fkey(shopify_order_id,order_number,total_value),attribution:order_attributions!revenue_ledger_attribution_id_fkey(attribution_method,attribution_confidence),billing:billing_measurements!billing_measurements_ledger_entry_id_fkey(henvalt_percentage,henvalt_fee,status)",
        tenant_id: "eq." + tenantId,
        entry_type: "eq.RECOVERY",
        attribution_confidence: "eq.CONFIRMED",
        created_at: "gte." + from + "T00:00:00.000Z",
        and: "(created_at.lt." + toExclusive + ")",
        order: "created_at.desc",
        limit: "50",
      }).toString();
      const ledgerResponse = await fetchImpl(ledgerUrl, {
        headers: {
          apikey: serviceRoleKey,
          authorization: "Bearer " + serviceRoleKey,
          "accept-profile": "henvalt",
        },
      });
      if (!ledgerResponse.ok) throw new Error("REVENUE_LEDGER_QUERY_FAILED");
      const ledger = await ledgerResponse.json();
      if (!Array.isArray(ledger)) throw new Error("REVENUE_LEDGER_INVALID_RESPONSE");

      return reply(200, {
        ...summary,
        ledger,
        revenueSeries: revenue?.series ?? [],
        revenueComparison: {
          currentRevenue: revenue?.current_revenue ?? summary.metrics?.revenueRecovered ?? 0,
          previousRevenue: revenue?.previous_revenue ?? 0,
          changePercent: revenue?.change_percent ?? null,
          previousFrom: revenue?.previous_from ?? null,
          previousTo: revenue?.previous_to ?? null,
        },
        range: { from, to, granularity },
        generatedAt: now().toISOString(),
      });
    } catch {
      return reply(500, { error: "dashboard_unavailable" });
    }
  };
}

if (import.meta.main) {
  const handler = createDashboardHandler({
    supabaseUrl: Deno.env.get("SUPABASE_URL") ?? "",
    serviceRoleKey: Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "",
    anonKey: Deno.env.get("SUPABASE_ANON_KEY") ?? "",
  });
  Deno.serve(handler);
}

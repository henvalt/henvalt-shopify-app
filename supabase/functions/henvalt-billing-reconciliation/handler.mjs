const RECONCILIATION_READ_RPC = "control_plane_get_billing_reconciliation";
const RECONCILIATION_RESOLVE_RPC = "control_plane_resolve_billing_reconciliation";

const cors = {
  "content-type": "application/json; charset=utf-8",
  "cache-control": "no-store",
  "access-control-allow-origin": "*",
  "access-control-allow-headers": "authorization, apikey, content-type, x-client-info",
  "access-control-allow-methods": "GET, POST, OPTIONS",
};

function reply(status, body) {
  return new Response(JSON.stringify(body), { status, headers: cors });
}

function validUuid(value) {
  return typeof value === "string" &&
    /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(value);
}

function validShop(value) {
  if (typeof value !== "string") return false;
  const parts = value.toLowerCase().split(".");
  return parts.length === 3 &&
    /^[a-z0-9][a-z0-9-]*$/.test(parts[0]) &&
    parts[1] === "myshopify" &&
    parts[2] === "com";
}

export function createBillingReconciliationHandler({ env, fetchImpl = fetch }) {
  async function serviceRequest(path, method = "GET", body) {
    if (!env.SUPABASE_URL || !env.SUPABASE_SERVICE_ROLE_KEY) {
      throw new Error("SERVICE_DATABASE_NOT_CONFIGURED");
    }
    const response = await fetchImpl(env.SUPABASE_URL + "/rest/v1/" + path, {
      method,
      redirect: "error",
      headers: {
        apikey: env.SUPABASE_SERVICE_ROLE_KEY,
        authorization: "Bearer " + env.SUPABASE_SERVICE_ROLE_KEY,
        "content-type": "application/json",
        "accept-profile": "henvalt",
        "content-profile": "henvalt",
        ...(body === undefined ? {} : { Prefer: "return=representation" }),
      },
      ...(body === undefined ? {} : { body: JSON.stringify(body) }),
      signal: AbortSignal.timeout(10000),
    });
    const text = await response.text();
    if (!response.ok) throw new Error("SERVICE_DATABASE_REQUEST_FAILED");
    return text ? JSON.parse(text) : null;
  }

  async function rpc(name, args) {
    return await serviceRequest("rpc/" + name, "POST", args);
  }

  async function authorize(req) {
    if (!env.SUPABASE_URL || !env.SUPABASE_ANON_KEY || !env.SUPABASE_SERVICE_ROLE_KEY) {
      return { response: reply(503, { error: "reconciliation_not_configured" }) };
    }
    const authorization = req.headers.get("authorization") ?? "";
    const token = authorization.match(/^Bearer\s+(.+)$/i)?.[1]?.trim() ?? "";
    if (!token) return { response: reply(401, { error: "sign_in_required" }) };

    const authResponse = await fetchImpl(env.SUPABASE_URL + "/auth/v1/user", {
      redirect: "error",
      headers: { apikey: env.SUPABASE_ANON_KEY, authorization: "Bearer " + token },
      signal: AbortSignal.timeout(10000),
    });
    if (!authResponse.ok) return { response: reply(401, { error: "invalid_session" }) };
    const user = await authResponse.json();
    if (!validUuid(user?.id)) return { response: reply(401, { error: "invalid_session" }) };

    const membershipUrl = new URL(env.SUPABASE_URL + "/rest/v1/tenant_memberships");
    membershipUrl.searchParams.set("select", "tenant_id,role");
    membershipUrl.searchParams.set("user_id", "eq." + user.id);
    membershipUrl.searchParams.set("role", "in.(OWNER,ADMIN)");
    membershipUrl.searchParams.set("limit", "2");
    const memberships = await serviceRequest(membershipUrl.pathname + membershipUrl.search);
    if (!Array.isArray(memberships) || memberships.length !== 1 ||
        !validUuid(memberships[0]?.tenant_id) ||
        !["OWNER", "ADMIN"].includes(memberships[0]?.role)) {
      return { response: reply(403, { error: "single_owner_or_admin_membership_required" }) };
    }

    const tenantId = memberships[0].tenant_id;
    const connectionUrl = new URL(env.SUPABASE_URL + "/rest/v1/shopify_connections");
    connectionUrl.searchParams.set("select", "shop_domain,active,tenants!inner(status)");
    connectionUrl.searchParams.set("tenant_id", "eq." + tenantId);
    connectionUrl.searchParams.set("active", "eq.true");
    connectionUrl.searchParams.set("tenants.status", "eq.ACTIVE");
    connectionUrl.searchParams.set("limit", "2");
    const connections = await serviceRequest(connectionUrl.pathname + connectionUrl.search);
    if (!Array.isArray(connections) || connections.length !== 1 ||
        !validShop(connections[0]?.shop_domain)) {
      return { response: reply(409, { error: "single_active_shop_connection_required" }) };
    }

    const billingUrl = new URL(env.SUPABASE_URL + "/rest/v1/billing_accounts");
    billingUrl.searchParams.set("select", "status,test_mode");
    billingUrl.searchParams.set("tenant_id", "eq." + tenantId);
    billingUrl.searchParams.set("status", "eq.ACTIVE");
    billingUrl.searchParams.set("limit", "2");
    const accounts = await serviceRequest(billingUrl.pathname + billingUrl.search);
    if (!Array.isArray(accounts) || accounts.length !== 1 || accounts[0]?.test_mode !== true) {
      return { response: reply(409, { error: "active_test_billing_account_required" }) };
    }

    return { userId: user.id, shop: connections[0].shop_domain.toLowerCase() };
  }

  return async function handle(req) {
    if (req.method === "OPTIONS") return new Response(null, { status: 204, headers: cors });
    if (req.method !== "GET" && req.method !== "POST") {
      return reply(405, { error: "method_not_allowed" });
    }

    try {
      const access = await authorize(req);
      if (access.response) return access.response;

      if (req.method === "GET") {
        const chargeId = new URL(req.url).searchParams.get("chargeId");
        if (!validUuid(chargeId)) return reply(400, { error: "valid_charge_id_required" });
        const result = await rpc(RECONCILIATION_READ_RPC, {
          p_shop_domain: access.shop,
          p_charge_id: chargeId,
        });
        if (result?.available !== true) return reply(404, { error: "reconciliation_case_not_found" });
        return reply(200, result);
      }

      const raw = await req.text();
      if (raw.length > 20000) return reply(413, { error: "body_too_large" });
      let body;
      try {
        body = JSON.parse(raw || "{}");
      } catch {
        return reply(400, { error: "invalid_json" });
      }
      if (body?.action !== "resolve" || !validUuid(body?.chargeId)) {
        return reply(400, { error: "valid_resolution_action_required" });
      }
      if (!["MATCHED", "NOT_FOUND_CONFIRMED", "MISMATCH"].includes(body?.resolution)) {
        return reply(400, { error: "invalid_resolution" });
      }
      if (!body?.evidence || typeof body.evidence !== "object" ||
          Array.isArray(body.evidence) ||
          new TextEncoder().encode(JSON.stringify(body.evidence)).length > 16384) {
        return reply(400, { error: "bounded_evidence_object_required" });
      }
      const note = typeof body.operatorNote === "string" ? body.operatorNote.trim() : "";
      if (note.length < 1 || note.length > 1000) {
        return reply(400, { error: "operator_note_required" });
      }
      const providerId = body.providerUsageRecordId == null ? null : body.providerUsageRecordId;
      if (providerId !== null && typeof providerId !== "string") {
        return reply(400, { error: "invalid_provider_usage_record_id" });
      }

      const result = await rpc(RECONCILIATION_RESOLVE_RPC, {
        p_shop_domain: access.shop,
        p_charge_id: body.chargeId,
        p_resolution: body.resolution,
        p_provider_usage_record_id: providerId,
        p_evidence: body.evidence,
        p_operator_reference: access.userId,
        p_operator_note: note,
      });
      if (result?.updated !== true) {
        return reply(409, { error: "reconciliation_state_changed", reason: result?.reason ?? "not_updated" });
      }
      return reply(200, result);
    } catch {
      return reply(503, { error: "reconciliation_temporarily_unavailable" });
    }
  };
}

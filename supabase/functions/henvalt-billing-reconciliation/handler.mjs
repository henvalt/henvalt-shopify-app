const RECONCILIATION_READ_RPC = "control_plane_get_billing_reconciliation";
const RECONCILIATION_RESOLVE_RPC = "control_plane_resolve_billing_reconciliation";
const SHOPIFY_TOKEN_RPC = "get_shopify_access_token_for_control_plane";
const SHOPIFY_API_VERSION = "2026-10";
const SUBSCRIPTIONS_QUERY = `query HenvaltReconciliationSubscriptions($first: Int!, $after: String) { currentAppInstallation { allSubscriptions(first: $first, after: $after) { edges { node { id test lineItems { id } } } pageInfo { hasNextPage endCursor } } } }`;
const USAGE_RECORDS_QUERY = `query HenvaltReconciliationUsageRecords($subscriptionId: ID!, $first: Int!, $after: String) { node(id: $subscriptionId) { ... on AppSubscription { id test lineItems { id usageRecords(first: $first, after: $after, reverse: true, sortKey: CREATED_AT) { edges { node { id idempotencyKey createdAt price { amount currencyCode } } } pageInfo { hasNextPage endCursor } } } } } }`;

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

function decimalEqual(a, b) {
  const canonical = (value) => {
    const raw = String(value ?? "");
    if (!/^[0-9]+(?:[.][0-9]+)?$/.test(raw)) return null;
    const [whole, fraction = ""] = raw.split(".");
    const integer = whole.replace(/^0+(?=\\d)/, "");
    const decimals = fraction.replace(/0+$/, "");
    return integer + (decimals ? "." + decimals : "");
  };
  const left = canonical(a);
  const right = canonical(b);
  return left !== null && right !== null && left === right;
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

  async function shopifyGraphQL(shop, accessToken, query, variables) {
    const response = await fetchImpl(
      "https://" + shop + "/admin/api/" + SHOPIFY_API_VERSION + "/graphql.json",
      {
        method: "POST",
        redirect: "error",
        headers: {
          "content-type": "application/json",
          "x-shopify-access-token": accessToken,
        },
        body: JSON.stringify({ query, variables }),
        signal: AbortSignal.timeout(15000),
      },
    );
    if (!response.ok) throw new Error("SHOPIFY_RECONCILIATION_LOOKUP_FAILED");
    const payload = await response.json();
    if (!payload || (Array.isArray(payload.errors) && payload.errors.length > 0)) {
      throw new Error("SHOPIFY_RECONCILIATION_LOOKUP_INCOMPLETE");
    }
    return payload.data;
  }

  async function lookupShopifyUsageRecords(shop, charge) {
    const tokenResult = await rpc(SHOPIFY_TOKEN_RPC, { p_shop_domain: shop });
    const accessToken = typeof tokenResult === "string"
      ? tokenResult
      : (typeof tokenResult?.access_token === "string" ? tokenResult.access_token : "");
    if (accessToken.length < 20) throw new Error("SHOPIFY_RECONCILIATION_TOKEN_UNAVAILABLE");

    let subscriptionAfter = null;
    let subscriptionPages = 0;
    const lineItemMatches = [];
    let subscriptionsComplete = false;
    while (subscriptionPages < 25) {
      const data = await shopifyGraphQL(shop, accessToken, SUBSCRIPTIONS_QUERY, {
        first: 50,
        after: subscriptionAfter,
      });
      const connection = data?.currentAppInstallation?.allSubscriptions;
      if (!connection || !Array.isArray(connection.edges) || !connection.pageInfo) {
        throw new Error("SHOPIFY_SUBSCRIPTION_LOOKUP_INCOMPLETE");
      }
      subscriptionPages += 1;
      for (const edge of connection.edges) {
        const subscription = edge?.node;
        if (!subscription || !Array.isArray(subscription.lineItems)) continue;
        for (const lineItem of subscription.lineItems) {
          if (lineItem?.id === charge.subscriptionLineItemId) {
            lineItemMatches.push({
              subscriptionId: subscription.id,
              test: subscription.test === true,
              lineItemId: lineItem.id,
            });
          }
        }
      }
      if (connection.pageInfo.hasNextPage !== true) {
        subscriptionsComplete = true;
        break;
      }
      if (typeof connection.pageInfo.endCursor !== "string" || !connection.pageInfo.endCursor) {
        throw new Error("SHOPIFY_SUBSCRIPTION_PAGINATION_INCOMPLETE");
      }
      subscriptionAfter = connection.pageInfo.endCursor;
    }
    if (!subscriptionsComplete) throw new Error("SHOPIFY_SUBSCRIPTION_PAGE_LIMIT_REACHED");
    if (lineItemMatches.length !== 1) {
      return {
        lookupComplete: true,
        subscriptionFound: false,
        lineItemFound: false,
        matchingCount: 0,
        pagesScanned: 0,
        matches: [],
      };
    }
    if (lineItemMatches[0].test !== true) {
      throw new Error("SHOPIFY_SUBSCRIPTION_IS_NOT_TEST_MODE");
    }

    let usageAfter = null;
    let usagePages = 0;
    let usageComplete = false;
    const matches = [];
    while (usagePages < 100) {
      const data = await shopifyGraphQL(shop, accessToken, USAGE_RECORDS_QUERY, {
        subscriptionId: lineItemMatches[0].subscriptionId,
        first: 50,
        after: usageAfter,
      });
      const subscription = data?.node;
      if (!subscription || subscription.id !== lineItemMatches[0].subscriptionId ||
          subscription.test !== true || !Array.isArray(subscription.lineItems)) {
        throw new Error("SHOPIFY_USAGE_RECORD_LOOKUP_INCOMPLETE");
      }
      const lineItem = subscription.lineItems.find((item) => item?.id === charge.subscriptionLineItemId);
      if (!lineItem || !lineItem.usageRecords ||
          !Array.isArray(lineItem.usageRecords.edges) || !lineItem.usageRecords.pageInfo) {
        throw new Error("SHOPIFY_USAGE_RECORD_CONNECTION_MISSING");
      }
      usagePages += 1;
      for (const edge of lineItem.usageRecords.edges) {
        const record = edge?.node;
        if (record?.idempotencyKey === charge.idempotencyKey) {
          matches.push({
            id: record.id,
            idempotencyKey: record.idempotencyKey,
            amount: record.price?.amount,
            currency: record.price?.currencyCode,
          });
        }
      }
      if (lineItem.usageRecords.pageInfo.hasNextPage !== true) {
        usageComplete = true;
        break;
      }
      if (typeof lineItem.usageRecords.pageInfo.endCursor !== "string" ||
          !lineItem.usageRecords.pageInfo.endCursor) {
        throw new Error("SHOPIFY_USAGE_RECORD_PAGINATION_INCOMPLETE");
      }
      usageAfter = lineItem.usageRecords.pageInfo.endCursor;
    }
    if (!usageComplete) throw new Error("SHOPIFY_USAGE_RECORD_PAGE_LIMIT_REACHED");

    return {
      lookupComplete: true,
      subscriptionFound: true,
      lineItemFound: true,
      matchingCount: matches.length,
      pagesScanned: usagePages,
      matches,
    };
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

    const membershipQuery = new URLSearchParams({
      select: "tenant_id,role",
      user_id: "eq." + user.id,
      role: "in.(OWNER,ADMIN)",
      limit: "2",
    });
    const memberships = await serviceRequest("tenant_memberships?" + membershipQuery.toString());
    if (!Array.isArray(memberships) || memberships.length !== 1 ||
        !validUuid(memberships[0]?.tenant_id) ||
        !["OWNER", "ADMIN"].includes(memberships[0]?.role)) {
      return { response: reply(403, { error: "single_owner_or_admin_membership_required" }) };
    }

    const tenantId = memberships[0].tenant_id;
    const connectionQuery = new URLSearchParams({
      select: "shop_domain,active,tenants!inner(status)",
      tenant_id: "eq." + tenantId,
      active: "eq.true",
      "tenants.status": "eq.ACTIVE",
      limit: "2",
    });
    const connections = await serviceRequest("shopify_connections?" + connectionQuery.toString());
    if (!Array.isArray(connections) || connections.length !== 1 ||
        !validShop(connections[0]?.shop_domain)) {
      return { response: reply(409, { error: "single_active_shop_connection_required" }) };
    }

    const billingQuery = new URLSearchParams({
      select: "status,test_mode",
      tenant_id: "eq." + tenantId,
      status: "eq.ACTIVE",
      limit: "2",
    });
    const accounts = await serviceRequest("billing_accounts?" + billingQuery.toString());
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
        if (chargeId === null) {
          const result = await rpc("control_plane_list_billing_reconciliations", {
            p_shop_domain: access.shop,
            p_limit: 50,
          });
          if (!Array.isArray(result?.cases)) throw new Error("INVALID_RECONCILIATION_LIST");
          return reply(200, result);
        }
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
      const note = typeof body.operatorNote === "string" ? body.operatorNote.trim() : "";
      if (note.length < 1 || note.length > 1000) {
        return reply(400, { error: "operator_note_required" });
      }

      // Never trust browser-supplied provider evidence. Read the persisted charge
      // envelope, then independently query Shopify using its stored idempotency key.
      const charge = await rpc(RECONCILIATION_READ_RPC, {
        p_shop_domain: access.shop,
        p_charge_id: body.chargeId,
      });
      if (charge?.available !== true) {
        return reply(409, { error: "reconciliation_state_changed" });
      }
      const lookup = await lookupShopifyUsageRecords(access.shop, charge);
      if (lookup.lookupComplete !== true || lookup.subscriptionFound !== true ||
          lookup.lineItemFound !== true) {
        return reply(409, { error: "shopify_subscription_line_item_not_found" });
      }

      const matches = lookup.matches;
      const record = matches.length === 1 ? matches[0] : null;
      const evidence = {
        lookupComplete: true,
        subscriptionFound: true,
        lineItemFound: true,
        providerUsageRecordId: record?.id ?? null,
        matchingCount: String(matches.length),
        idempotencyKey: charge.idempotencyKey,
        lineItemId: charge.subscriptionLineItemId,
        amount: record?.amount ?? null,
        currency: record?.currency ?? null,
        pagesScanned: lookup.pagesScanned,
      };

      if (body.resolution === "MATCHED") {
        if (matches.length !== 1 || !record?.id ||
            !decimalEqual(record.amount, charge.amount) ||
            record.currency !== charge.currency) {
          return reply(409, { error: "shopify_record_does_not_match_charge" });
        }
      } else if (body.resolution === "NOT_FOUND_CONFIRMED" && matches.length !== 0) {
        return reply(409, { error: "shopify_record_exists_use_matched_or_mismatch" });
      }

      const result = await rpc(RECONCILIATION_RESOLVE_RPC, {
        p_shop_domain: access.shop,
        p_charge_id: body.chargeId,
        p_resolution: body.resolution,
        p_provider_usage_record_id: body.resolution === "MATCHED" ? record.id : null,
        p_evidence: evidence,
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

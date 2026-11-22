import test from "node:test";
import assert from "node:assert/strict";
import { createBillingReconciliationHandler } from "../supabase/functions/henvalt-billing-reconciliation/handler.mjs";

const env = {
  SUPABASE_URL: "https://supabase.invalid",
  SUPABASE_ANON_KEY: "anon-test-key",
  SUPABASE_SERVICE_ROLE_KEY: "service-role-test-key",
};
const userId = "11111111-1111-4111-8111-111111111111";
const tenantId = "22222222-2222-4222-8222-222222222222";
const chargeId = "33333333-3333-4333-8333-333333333333";
const shop = "reconcile.myshopify.com";
const lineItemId = "gid://shopify/AppSubscriptionLineItem/777";
const subscriptionId = "gid://shopify/AppSubscription/888";
const providerRecordId = "gid://shopify/AppUsageRecord/999";
const idempotencyKey = "henvalt-charge-key-001";

function response(body, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json" },
  });
}

function request(method = "GET", body, token = "valid-user-token") {
  const url = method === "GET"
    ? "https://edge.invalid/reconciliation?chargeId=" + chargeId
    : "https://edge.invalid/reconciliation";
  return new Request(url, {
    method,
    headers: {
      authorization: "Bearer " + token,
      ...(body === undefined ? {} : { "content-type": "application/json" }),
    },
    ...(body === undefined ? {} : { body: JSON.stringify(body) }),
  });
}

function harness({
  memberships = [{ tenant_id: tenantId, role: "OWNER" }],
  connections = [{ shop_domain: shop, active: true }],
  accounts = [{ status: "ACTIVE", test_mode: true }],
  readResult = {
    available: true,
    chargeId,
    shop,
    amount: "10.0000",
    currency: "USD",
    idempotencyKey,
    subscriptionLineItemId: lineItemId,
  },
  resolveResult = { updated: true, status: "SUBMITTED", chargeId },
  usageRecords = [{
    id: providerRecordId,
    idempotencyKey,
    price: { amount: "10.00", currencyCode: "USD" },
    subscriptionLineItem: { id: lineItemId },
  }],
  subscriptionTest = true,
  subscriptionPageInfo = { hasNextPage: false, endCursor: null },
  usagePageInfo = { hasNextPage: false, endCursor: null },
  subscriptionPages = null,
  usagePages = null,
} = {}) {
  const calls = [];
  let subscriptionPageIndex = 0;
  let usagePageIndex = 0;
  const fetchImpl = async (url, init = {}) => {
    calls.push({ url: String(url), init });
    const parsed = new URL(String(url));
    if (parsed.pathname === "/auth/v1/user") return response({ id: userId });
    if (parsed.pathname === "/rest/v1/tenant_memberships") return response(memberships);
    if (parsed.pathname === "/rest/v1/shopify_connections") return response(connections);
    if (parsed.pathname === "/rest/v1/billing_accounts") return response(accounts);
    if (parsed.pathname === "/rest/v1/rpc/control_plane_list_billing_reconciliations") return response({ cases: [{ chargeId, shop }], count: 1 });
    if (parsed.pathname === "/rest/v1/rpc/control_plane_get_billing_reconciliation") return response(readResult);
    if (parsed.pathname === "/rest/v1/rpc/get_shopify_access_token_for_control_plane") return response("test-shopify-access-token-0123456789");
    if (parsed.pathname === "/rest/v1/rpc/control_plane_resolve_billing_reconciliation") return response(resolveResult);
    if (parsed.pathname === "/admin/api/2026-10/graphql.json") {
      const body = JSON.parse(init.body);
      if (body.query.includes("currentAppInstallation")) {
        const page = subscriptionPages?.[subscriptionPageIndex++] ?? {
          edges: [{
            node: {
              id: subscriptionId,
              test: subscriptionTest,
              lineItems: [{ id: lineItemId }],
            },
          }],
          pageInfo: subscriptionPageInfo,
        };
        return response({ data: { currentAppInstallation: { allSubscriptions: page } } });
      }
      if (body.query.includes("HenvaltReconciliationUsageRecords")) {
        const page = usagePages?.[usagePageIndex++] ?? {
          records: usageRecords,
          pageInfo: usagePageInfo,
        };
        return response({
          data: {
            node: {
              id: subscriptionId,
              test: subscriptionTest,
              lineItems: [{
                id: lineItemId,
                usageRecords: {
                  edges: page.records.map((node) => ({ node })),
                  pageInfo: page.pageInfo,
                },
              }],
            },
          },
        });
      }
      throw new Error("Unexpected Shopify GraphQL query");
    }
    throw new Error("Unexpected outbound request: " + url);
  };
  return { calls, fetchImpl };
}

test("rejects unauthenticated requests before any service-role lookup", async () => {
  const h = harness();
  const handler = createBillingReconciliationHandler({ env, fetchImpl: h.fetchImpl });
  const result = await handler(request("GET", undefined, ""));
  assert.equal(result.status, 401);
  assert.equal(h.calls.length, 0);
});

test("rejects member-only users and users with ambiguous owner/admin memberships", async () => {
  for (const memberships of [
    [{ tenant_id: tenantId, role: "MEMBER" }],
    [{ tenant_id: tenantId, role: "OWNER" }, { tenant_id: "44444444-4444-4444-8444-444444444444", role: "ADMIN" }],
  ]) {
    const h = harness({ memberships });
    const handler = createBillingReconciliationHandler({ env, fetchImpl: h.fetchImpl });
    const result = await handler(request());
    assert.equal(result.status, 403);
    assert.equal(h.calls.some((call) => call.url.includes("/rpc/")), false);
  }
});

test("requires one active test-mode billing account before reading reconciliation data", async () => {
  const h = harness({ accounts: [{ status: "ACTIVE", test_mode: false }] });
  const handler = createBillingReconciliationHandler({ env, fetchImpl: h.fetchImpl });
  const result = await handler(request());
  assert.equal(result.status, 409);
  assert.equal(h.calls.some((call) => call.url.includes("/rpc/")), false);
});

test("lists only unresolved cases for the authenticated owner's database-derived shop", async () => {
  const h = harness();
  const handler = createBillingReconciliationHandler({ env, fetchImpl: h.fetchImpl });
  const result = await handler(new Request("https://edge.invalid/reconciliation", {
    method: "GET",
    headers: { authorization: "Bearer valid-user-token" },
  }));
  assert.equal(result.status, 200);
  const body = await result.json();
  assert.equal(body.count, 1);
  const call = h.calls.find((item) => item.url.includes("/control_plane_list_billing_reconciliations"));
  assert.ok(call);
  assert.deepEqual(JSON.parse(call.init.body), { p_shop_domain: shop, p_limit: 50 });
});

test("reads only the authenticated owner's database-derived shop and charge", async () => {
  const h = harness();
  const handler = createBillingReconciliationHandler({ env, fetchImpl: h.fetchImpl });
  const result = await handler(request());
  assert.equal(result.status, 200);
  const call = h.calls.find((item) => item.url.includes("/control_plane_get_billing_reconciliation"));
  assert.ok(call);
  const args = JSON.parse(call.init.body);
  assert.equal(args.p_shop_domain, shop);
  assert.equal(args.p_charge_id, chargeId);
  assert.equal(call.init.headers.authorization, "Bearer " + env.SUPABASE_SERVICE_ROLE_KEY);
});

test("verifies the exact Shopify usage record before settling a matched charge", async () => {
  const h = harness();
  const handler = createBillingReconciliationHandler({ env, fetchImpl: h.fetchImpl });
  const result = await handler(request("POST", {
    action: "resolve",
    chargeId,
    resolution: "MATCHED",
    providerUsageRecordId: "gid://shopify/AppUsageRecord/attacker-value",
    evidence: { lookupComplete: true, matchingCount: "0", idempotencyKey: "forged-key" },
    operatorNote: "Verified against Shopify usage records",
    shop: "attacker.myshopify.com",
    tenantId: "55555555-5555-4555-8555-555555555555",
    operatorReference: "forged-operator",
  }));
  assert.equal(result.status, 200);
  const tokenCall = h.calls.find((item) => item.url.includes("/get_shopify_access_token_for_control_plane"));
  assert.ok(tokenCall);
  const graphCalls = h.calls.filter((item) => item.url.includes("/admin/api/2026-10/graphql.json"));
  assert.equal(graphCalls.length, 2);
  assert.ok(JSON.parse(graphCalls[0].init.body).query.includes("allSubscriptions"));
  assert.ok(JSON.parse(graphCalls[1].init.body).query.includes("idempotencyKey"));
  assert.equal(graphCalls[0].init.headers["x-shopify-access-token"], "test-shopify-access-token-0123456789");

  const call = h.calls.find((item) => item.url.includes("/control_plane_resolve_billing_reconciliation"));
  assert.ok(call);
  const args = JSON.parse(call.init.body);
  assert.equal(args.p_shop_domain, shop);
  assert.equal(args.p_charge_id, chargeId);
  assert.equal(args.p_operator_reference, userId);
  assert.equal(args.p_provider_usage_record_id, providerRecordId);
  assert.equal(args.p_operator_note, "Verified against Shopify usage records");
  assert.equal(args.p_evidence.idempotencyKey, idempotencyKey);
  assert.equal(args.p_evidence.matchingCount, "1");
  assert.equal(args.p_evidence.amount, "10.00");
  assert.equal(args.p_evidence.currency, "USD");
});

test("rejects a provider record whose own subscriptionLineItem ID differs from the stored line item", async () => {
  const h = harness({
    usageRecords: [{
      id: providerRecordId,
      idempotencyKey,
      price: { amount: "10.00", currencyCode: "USD" },
      subscriptionLineItem: { id: "gid://shopify/AppSubscriptionLineItem/wrong" },
    }],
  });
  const handler = createBillingReconciliationHandler({ env, fetchImpl: h.fetchImpl });
  const result = await handler(request("POST", {
    action: "resolve",
    chargeId,
    resolution: "MATCHED",
    operatorNote: "Verify line item identity",
  }));
  assert.equal(result.status, 409);
  assert.equal((await result.json()).error, "shopify_record_does_not_match_charge");
  assert.equal(h.calls.some((call) => call.url.includes("/control_plane_resolve_billing_reconciliation")), false);
});

test("does not accept browser-supplied evidence when Shopify has no matching record", async () => {
  const h = harness({ usageRecords: [] });
  const handler = createBillingReconciliationHandler({ env, fetchImpl: h.fetchImpl });
  const result = await handler(request("POST", {
    action: "resolve",
    chargeId,
    resolution: "MATCHED",
    evidence: { lookupComplete: true, matchingCount: "1", idempotencyKey },
    operatorNote: "Browser claims that the provider accepted it",
  }));
  assert.equal(result.status, 409);
  assert.equal((await result.json()).error, "shopify_record_does_not_match_charge");
  assert.equal(h.calls.some((call) => call.url.includes("/control_plane_resolve_billing_reconciliation")), false);
});

test("rejects MATCHED when the real Shopify amount or currency differs from the charge", async () => {
  const h = harness({
    usageRecords: [{
      id: providerRecordId,
      idempotencyKey,
      price: { amount: "12.00", currencyCode: "USD" },
      subscriptionLineItem: { id: lineItemId },
    }],
  });
  const handler = createBillingReconciliationHandler({ env, fetchImpl: h.fetchImpl });
  const result = await handler(request("POST", {
    action: "resolve",
    chargeId,
    resolution: "MATCHED",
    operatorNote: "Attempt to match an amount mismatch",
  }));
  assert.equal(result.status, 409);
  assert.equal((await result.json()).error, "shopify_record_does_not_match_charge");
  assert.equal(h.calls.some((call) => call.url.includes("/control_plane_resolve_billing_reconciliation")), false);
});

test("MISMATCH records only the provider evidence returned by Shopify", async () => {
  const h = harness({
    usageRecords: [{
      id: providerRecordId,
      idempotencyKey,
      price: { amount: "12.00", currencyCode: "USD" },
      subscriptionLineItem: { id: lineItemId },
    }],
  });
  const handler = createBillingReconciliationHandler({ env, fetchImpl: h.fetchImpl });
  const result = await handler(request("POST", {
    action: "resolve",
    chargeId,
    resolution: "MISMATCH",
    evidence: { amount: "10.00", matchingCount: "0" },
    operatorNote: "Provider amount does not match the measured fee",
  }));
  assert.equal(result.status, 200);
  const call = h.calls.find((item) => item.url.includes("/control_plane_resolve_billing_reconciliation"));
  const args = JSON.parse(call.init.body);
  assert.equal(args.p_resolution, "MISMATCH");
  assert.equal(args.p_provider_usage_record_id, null);
  assert.equal(args.p_evidence.amount, "12.00");
  assert.equal(args.p_evidence.matchingCount, "1");
});

test("finds the exact subscription line item across subscription pages", async () => {
  const h = harness({
    subscriptionPages: [
      {
        edges: [{ node: { id: "gid://shopify/AppSubscription/old", test: true, lineItems: [{ id: "gid://shopify/AppSubscriptionLineItem/other" }] } }],
        pageInfo: { hasNextPage: true, endCursor: "subscriptions-cursor-1" },
      },
      {
        edges: [{ node: { id: subscriptionId, test: true, lineItems: [{ id: lineItemId }] } }],
        pageInfo: { hasNextPage: false, endCursor: "subscriptions-cursor-2" },
      },
    ],
  });
  const handler = createBillingReconciliationHandler({ env, fetchImpl: h.fetchImpl });
  const result = await handler(request("POST", {
    action: "resolve",
    chargeId,
    resolution: "MATCHED",
    operatorNote: "Found the owning subscription after pagination",
  }));
  assert.equal(result.status, 200);
  const subscriptionCalls = h.calls.filter((item) => item.url.includes("/admin/api/2026-10/graphql.json") && JSON.parse(item.init.body).query.includes("currentAppInstallation"));
  assert.equal(subscriptionCalls.length, 2);
});

test("permits confirmed no-match only after complete Shopify pagination", async () => {
  const h = harness({ usageRecords: [] });
  const handler = createBillingReconciliationHandler({ env, fetchImpl: h.fetchImpl });
  const result = await handler(request("POST", {
    action: "resolve",
    chargeId,
    resolution: "NOT_FOUND_CONFIRMED",
    operatorNote: "Completed the full usage-record lookup",
  }));
  assert.equal(result.status, 200);
  const call = h.calls.find((item) => item.url.includes("/control_plane_resolve_billing_reconciliation"));
  const args = JSON.parse(call.init.body);
  assert.equal(args.p_resolution, "NOT_FOUND_CONFIRMED");
  assert.equal(args.p_evidence.lookupComplete, true);
  assert.equal(args.p_evidence.matchingCount, "0");
  assert.equal(args.p_evidence.pagesScanned, 1);
  assert.equal(args.p_provider_usage_record_id, null);
});

test("refuses no-match resolution if Shopify reports an existing matching record", async () => {
  const h = harness();
  const handler = createBillingReconciliationHandler({ env, fetchImpl: h.fetchImpl });
  const result = await handler(request("POST", {
    action: "resolve",
    chargeId,
    resolution: "NOT_FOUND_CONFIRMED",
    operatorNote: "Try to retry despite existing usage record",
  }));
  assert.equal(result.status, 409);
  assert.equal((await result.json()).error, "shopify_record_exists_use_matched_or_mismatch");
  assert.equal(h.calls.some((call) => call.url.includes("/control_plane_resolve_billing_reconciliation")), false);
});

test("refuses incomplete usage-record pagination before confirming no-match", async () => {
  const h = harness({ usageRecords: [], usagePageInfo: { hasNextPage: true, endCursor: null } });
  const handler = createBillingReconciliationHandler({ env, fetchImpl: h.fetchImpl });
  const result = await handler(request("POST", {
    action: "resolve",
    chargeId,
    resolution: "NOT_FOUND_CONFIRMED",
    operatorNote: "Attempt incomplete usage-record lookup",
  }));
  assert.equal(result.status, 503);
  assert.equal(h.calls.some((call) => call.url.includes("/control_plane_resolve_billing_reconciliation")), false);
});

test("requires every usage-record page to complete before confirming no-match", async () => {
  const h = harness({
    usagePages: [
      { records: [], pageInfo: { hasNextPage: true, endCursor: "usage-cursor-1" } },
      { records: [], pageInfo: { hasNextPage: false, endCursor: "usage-cursor-2" } },
    ],
  });
  const handler = createBillingReconciliationHandler({ env, fetchImpl: h.fetchImpl });
  const result = await handler(request("POST", {
    action: "resolve",
    chargeId,
    resolution: "NOT_FOUND_CONFIRMED",
    operatorNote: "Completed both usage-record pages",
  }));
  assert.equal(result.status, 200);
  const call = h.calls.find((item) => item.url.includes("/control_plane_resolve_billing_reconciliation"));
  assert.equal(JSON.parse(call.init.body).p_evidence.pagesScanned, 2);
});

test("refuses incomplete Shopify subscription pagination and records no decision", async () => {
  const h = harness({ subscriptionPageInfo: { hasNextPage: true, endCursor: null } });
  const handler = createBillingReconciliationHandler({ env, fetchImpl: h.fetchImpl });
  const result = await handler(request("POST", {
    action: "resolve",
    chargeId,
    resolution: "NOT_FOUND_CONFIRMED",
    operatorNote: "Attempt incomplete lookup",
  }));
  assert.equal(result.status, 503);
  assert.equal(h.calls.some((call) => call.url.includes("/control_plane_resolve_billing_reconciliation")), false);
});

test("rejects invalid resolution and missing operator note before provider lookup", async () => {
  for (const body of [
    { action: "resolve", chargeId, resolution: "CHARGE_ANYTHING", operatorNote: "x" },
    { action: "resolve", chargeId, resolution: "MATCHED", operatorNote: "" },
  ]) {
    const h = harness();
    const handler = createBillingReconciliationHandler({ env, fetchImpl: h.fetchImpl });
    const result = await handler(request("POST", body));
    assert.equal(result.status, 400);
    assert.equal(h.calls.some((call) => call.url.includes("/admin/api/")), false);
    assert.equal(h.calls.some((call) => call.url.includes("/control_plane_resolve_billing_reconciliation")), false);
  }
});

test("requires Shopify test-mode subscription attestation", async () => {
  const h = harness({ subscriptionTest: false });
  const handler = createBillingReconciliationHandler({ env, fetchImpl: h.fetchImpl });
  const result = await handler(request("POST", {
    action: "resolve",
    chargeId,
    resolution: "MATCHED",
    operatorNote: "Test mode mismatch",
  }));
  assert.equal(result.status, 409);
  assert.equal((await result.json()).error, "shopify_subscription_is_not_test_mode");
  assert.equal(h.calls.some((call) => call.url.includes("/control_plane_resolve_billing_reconciliation")), false);
});

test("returns conflict when the database refuses a stale or already-resolved case", async () => {
  const h = harness({ resolveResult: { updated: false, reason: "CHARGE_NOT_ELIGIBLE" } });
  const handler = createBillingReconciliationHandler({ env, fetchImpl: h.fetchImpl });
  const result = await handler(request("POST", {
    action: "resolve",
    chargeId,
    resolution: "MISMATCH",
    operatorNote: "Stop for further review",
  }));
  assert.equal(result.status, 409);
});

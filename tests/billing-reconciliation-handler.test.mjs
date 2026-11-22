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
  readResult = { available: true, chargeId, shop },
  resolveResult = { updated: true, status: "SUBMITTED", chargeId },
} = {}) {
  const calls = [];
  const fetchImpl = async (url, init = {}) => {
    calls.push({ url: String(url), init });
    const parsed = new URL(String(url));
    if (parsed.pathname === "/auth/v1/user") return response({ id: userId });
    if (parsed.pathname === "/rest/v1/tenant_memberships") return response(memberships);
    if (parsed.pathname === "/rest/v1/shopify_connections") return response(connections);
    if (parsed.pathname === "/rest/v1/billing_accounts") return response(accounts);
    if (parsed.pathname === "/rest/v1/rpc/control_plane_get_billing_reconciliation") return response(readResult);
    if (parsed.pathname === "/rest/v1/rpc/control_plane_resolve_billing_reconciliation") return response(resolveResult);
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

test("resolves a case with server-derived tenant, shop and authenticated operator identity", async () => {
  const h = harness();
  const handler = createBillingReconciliationHandler({ env, fetchImpl: h.fetchImpl });
  const result = await handler(request("POST", {
    action: "resolve",
    chargeId,
    resolution: "MATCHED",
    providerUsageRecordId: "gid://shopify/AppUsageRecord/123",
    evidence: { lookupComplete: true, matchingCount: "1" },
    operatorNote: "Verified against Shopify usage records",
    shop: "attacker.myshopify.com",
    tenantId: "55555555-5555-4555-8555-555555555555",
    operatorReference: "forged-operator",
  }));
  assert.equal(result.status, 200);
  const call = h.calls.find((item) => item.url.includes("/control_plane_resolve_billing_reconciliation"));
  assert.ok(call);
  const args = JSON.parse(call.init.body);
  assert.equal(args.p_shop_domain, shop);
  assert.equal(args.p_charge_id, chargeId);
  assert.equal(args.p_operator_reference, userId);
  assert.equal(args.p_provider_usage_record_id, "gid://shopify/AppUsageRecord/123");
  assert.equal(args.p_operator_note, "Verified against Shopify usage records");
});

test("rejects invalid resolution and unbounded evidence before invoking the RPC", async () => {
  for (const body of [
    { action: "resolve", chargeId, resolution: "CHARGE_ANYTHING", evidence: {}, operatorNote: "x" },
    { action: "resolve", chargeId, resolution: "MATCHED", evidence: { data: "x".repeat(17000) }, operatorNote: "x" },
    { action: "resolve", chargeId, resolution: "MATCHED", evidence: {}, operatorNote: "" },
  ]) {
    const h = harness();
    const handler = createBillingReconciliationHandler({ env, fetchImpl: h.fetchImpl });
    const result = await handler(request("POST", body));
    assert.equal(result.status, 400);
    assert.equal(h.calls.some((call) => call.url.includes("/rpc/control_plane_resolve_billing_reconciliation")), false);
  }
});

test("returns conflict when the database refuses a stale or already-resolved case", async () => {
  const h = harness({ resolveResult: { updated: false, reason: "CHARGE_NOT_ELIGIBLE" } });
  const handler = createBillingReconciliationHandler({ env, fetchImpl: h.fetchImpl });
  const result = await handler(request("POST", {
    action: "resolve",
    chargeId,
    resolution: "MISMATCH",
    evidence: { reason: "provider evidence mismatch" },
    operatorNote: "Stop for further review",
  }));
  assert.equal(result.status, 409);
});

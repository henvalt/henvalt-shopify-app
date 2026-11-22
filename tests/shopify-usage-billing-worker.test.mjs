import test from "node:test";
import assert from "node:assert/strict";
import { createShopifyUsageBillingHandler } from "../supabase/functions/henvalt-shopify-usage-billing/handler.mjs";

const shop = "billing-test.myshopify.com";
const charge = {
  available: true,
  chargeId: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
  subscriptionLineItemId: "gid://shopify/AppSubscriptionLineItem/12345",
  amount: "7.25",
  currency: "USD",
  idempotencyKey: "henvalt-recovery-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
};
const env = {
  SUPABASE_URL: "https://supabase.invalid",
  SUPABASE_SERVICE_ROLE_KEY: "service-role-test-secret",
  HENVALT_BILLING_WORKER_TOKEN: "billing-worker-test-secret",
};
const quiet = { error() {} };

function response(body, status = 200) {
  return new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json" } });
}

function request(body = { shop }, token = env.HENVALT_BILLING_WORKER_TOKEN) {
  return new Request("https://edge.invalid/billing", {
    method: "POST",
    headers: token ? { authorization: "Bearer " + token, "content-type": "application/json" } : {},
    body: JSON.stringify(body),
  });
}

function harness({ claim = charge, shopify = response({ data: { appUsageRecordCreate: { appUsageRecord: { id: "gid://shopify/AppUsageRecord/999" }, userErrors: [] } } }), failShopify = false, failResult = false } = {}) {
  const calls = [];
  const fetchImpl = async (url, init = {}) => {
    calls.push({ url: String(url), init });
    if (String(url).includes("/get_shopify_access_token_for_control_plane")) return response("shpat_test_access_token_1234567890");
    if (String(url).includes("/control_plane_claim_billing_usage")) return response(claim);
    if (String(url).includes("/admin/api/")) {
      if (failShopify) throw new Error("socket closed after write");
      return shopify;
    }
    if (String(url).includes("/control_plane_record_billing_usage_result")) {
      if (failResult) return response({ message: "db unavailable" }, 503);
      return response({ updated: true, status: "SUBMITTED" });
    }
    throw new Error("Unexpected outbound request: " + url);
  };
  return { calls, fetchImpl };
}

test("rejects unauthenticated requests before any database or provider request", async () => {
  let calls = 0;
  const handler = createShopifyUsageBillingHandler({ env, fetchImpl: async () => { calls++; throw new Error("must not call"); }, logger: quiet });
  const result = await handler(request({ shop }, ""));
  assert.equal(result.status, 401);
  assert.equal(calls, 0);
});

test("validates shop before obtaining credentials", async () => {
  let calls = 0;
  const handler = createShopifyUsageBillingHandler({ env, fetchImpl: async () => { calls++; }, logger: quiet });
  const result = await handler(request({ shop: "evil.example" }));
  assert.equal(result.status, 400);
  assert.equal(calls, 0);
});

test("claims one usage measurement and sends exact amount with persisted Shopify idempotency key", async () => {
  const h = harness();
  const handler = createShopifyUsageBillingHandler({ env, fetchImpl: h.fetchImpl, logger: quiet });
  const result = await handler(request());
  assert.equal(result.status, 200);
  assert.deepEqual(await result.json(), { claimed: true, state: "SUBMITTED", providerUsageRecordId: "gid://shopify/AppUsageRecord/999" });
  const provider = h.calls.find((call) => call.url.includes("/admin/api/"));
  const body = JSON.parse(provider.init.body);
  assert.equal(body.variables.price.amount, "7.25");
  assert.equal(body.variables.price.currencyCode, "USD");
  assert.equal(body.variables.subscriptionLineItemId, charge.subscriptionLineItemId);
  assert.equal(body.variables.idempotencyKey, charge.idempotencyKey);
  assert.equal(provider.init.redirect, "error");
  assert.ok(h.calls.some((call) => call.url.includes("/control_plane_record_billing_usage_result")));
});

test("does not charge when the database has no eligible measurement", async () => {
  const h = harness({ claim: { available: false, reason: "NO_PENDING_USAGE_CHARGE" } });
  const handler = createShopifyUsageBillingHandler({ env, fetchImpl: h.fetchImpl, logger: quiet });
  const result = await handler(request());
  assert.equal(result.status, 200);
  assert.equal((await result.json()).claimed, false);
  assert.equal(h.calls.some((call) => call.url.includes("/admin/api/")), false);
});

test("keeps ambiguous provider transport failures PENDING and does not mark them FAILED", async () => {
  const h = harness({ failShopify: true });
  const handler = createShopifyUsageBillingHandler({ env, fetchImpl: h.fetchImpl, logger: quiet });
  const result = await handler(request());
  assert.equal(result.status, 202);
  assert.equal((await result.json()).state, "PENDING");
  assert.equal(h.calls.some((call) => call.url.includes("/control_plane_record_billing_usage_result")), false);
});

test("keeps Shopify 5xx and malformed responses PENDING", async () => {
  for (const shopify of [response({ error: "temporary" }, 503), new Response("not-json", { status: 200 })]) {
    const h = harness({ shopify });
    const handler = createShopifyUsageBillingHandler({ env, fetchImpl: h.fetchImpl, logger: quiet });
    const result = await handler(request());
    assert.equal(result.status, 202);
    assert.equal((await result.json()).state, "PENDING");
    assert.equal(h.calls.some((call) => call.url.includes("/control_plane_record_billing_usage_result")), false);
  }
});

test("treats Shopify idempotency concurrency as pending, not a failed charge", async () => {
  const h = harness({ shopify: response({ data: { appUsageRecordCreate: {
    appUsageRecord: null,
    userErrors: [{ code: "IDEMPOTENCY_CONCURRENT_REQUEST", message: "Another request for the same idempotency key is being processed." }],
  } } }) });
  const handler = createShopifyUsageBillingHandler({ env, fetchImpl: h.fetchImpl, logger: quiet });
  const result = await handler(request());
  assert.equal(result.status, 202);
  assert.equal((await result.json()).reason, "SHOPIFY_IDEMPOTENCY_REQUEST_IN_PROGRESS");
  assert.equal(h.calls.some((call) => call.url.includes("/control_plane_record_billing_usage_result")), false);
});

test("records explicit Shopify userErrors as a failed usage attempt", async () => {
  const h = harness({ shopify: response({ data: { appUsageRecordCreate: {
    appUsageRecord: null,
    userErrors: [{ field: ["price"], message: "Usage exceeds the capped amount." }],
  } } }) });
  const handler = createShopifyUsageBillingHandler({ env, fetchImpl: h.fetchImpl, logger: quiet });
  const result = await handler(request());
  assert.equal(result.status, 422);
  const call = h.calls.find((item) => item.url.includes("/control_plane_record_billing_usage_result"));
  assert.ok(call);
  assert.equal(JSON.parse(call.init.body).p_success, false);
});

test("uses the same persisted idempotency key if Shopify accepted but local result recording failed", async () => {
  const h = harness({ failResult: true });
  const handler = createShopifyUsageBillingHandler({ env, fetchImpl: h.fetchImpl, logger: quiet });
  const result = await handler(request());
  assert.equal(result.status, 503);
  assert.equal((await result.json()).state, "PENDING");
  const provider = h.calls.find((call) => call.url.includes("/admin/api/"));
  assert.equal(JSON.parse(provider.init.body).variables.idempotencyKey, charge.idempotencyKey);
});

test("rejects malformed charge envelopes without contacting Shopify", async () => {
  const h = harness({ claim: { ...charge, idempotencyKey: "x".repeat(256) } });
  const handler = createShopifyUsageBillingHandler({ env, fetchImpl: h.fetchImpl, logger: quiet });
  const result = await handler(request());
  assert.equal(result.status, 503);
  assert.equal(h.calls.some((call) => call.url.includes("/admin/api/")), false);
});

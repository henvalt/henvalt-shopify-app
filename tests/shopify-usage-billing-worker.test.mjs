import test from "node:test";
import assert from "node:assert/strict";
import { createShopifyUsageBillingHandler } from "../supabase/functions/henvalt-shopify-usage-billing/handler.mjs";
import { readFileSync } from "node:fs";
import { buildRecoveryBillingCandidate } from "../n8n/shopify-recovery-billing-candidate-builder.mjs";

const shop = "billing-test.myshopify.com";
const charge = {
  available: true,
  chargeId: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
  subscriptionLineItemId: "gid://shopify/AppSubscriptionLineItem/12345",
  amount: "7.25",
  currency: "USD",
  idempotencyKey: "henvalt-recovery-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
  attempt: 1,
  testMode: true,
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

function harness({ claim = charge, shopify = response({ data: { appUsageRecordCreate: { appUsageRecord: { id: "gid://shopify/AppUsageRecord/999" }, userErrors: [] } } }), failShopify = false, failResult = false, failReconciliation = false } = {}) {
  const calls = [];
  const fetchImpl = async (url, init = {}) => {
    calls.push({ url: String(url), init });
    if (String(url).includes("/get_shopify_access_token_for_control_plane")) return response("shpat_test_access_token_1234567890");
    if (String(url).includes("/control_plane_claim_billing_usage")) return response(claim);
    if (String(url).includes("/admin/api/")) {
      if (failShopify) throw new Error("socket closed after write");
      return shopify;
    }
    if (String(url).includes("/control_plane_mark_billing_reconciliation_required")) {
      if (failReconciliation) return response({ message: "db unavailable" }, 503);
      return response({ updated: true, status: "REQUIRED" });
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
  assert.ok(h.calls.findIndex((call) => call.url.includes("/control_plane_claim_billing_usage")) < h.calls.findIndex((call) => call.url.includes("/get_shopify_access_token_for_control_plane")));
});

test("does not charge when the database has no eligible measurement", async () => {
  const h = harness({ claim: { available: false, reason: "NO_PENDING_USAGE_CHARGE" } });
  const handler = createShopifyUsageBillingHandler({ env, fetchImpl: h.fetchImpl, logger: quiet });
  const result = await handler(request());
  assert.equal(result.status, 200);
  assert.equal((await result.json()).claimed, false);
  assert.equal(h.calls.some((call) => call.url.includes("/admin/api/")), false);
  assert.equal(h.calls.some((call) => call.url.includes("/get_shopify_access_token_for_control_plane")), false);
});

test("refuses live-mode or unverified claims before obtaining credentials or contacting Shopify", async () => {
  for (const claim of [{ ...charge, testMode: false }, { ...charge, testMode: undefined }]) {
    const h = harness({ claim });
    const handler = createShopifyUsageBillingHandler({ env, fetchImpl: h.fetchImpl, logger: quiet });
    const result = await handler(request());
    assert.equal(result.status, 409);
    assert.equal((await result.json()).error, "test_mode_required");
    assert.equal(h.calls.some((call) => call.url.includes("/get_shopify_access_token_for_control_plane")), false);
    assert.equal(h.calls.some((call) => call.url.includes("/admin/api/")), false);
  }
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

test("persists durable reconciliation when the fifth ambiguous attempt is exhausted", async () => {
  const h = harness({ claim: { ...charge, attempt: 5 }, failShopify: true });
  const handler = createShopifyUsageBillingHandler({ env, fetchImpl: h.fetchImpl, logger: quiet });
  const result = await handler(request());
  const body = await result.json();
  assert.equal(result.status, 202);
  assert.equal(body.retryable, false);
  assert.equal(body.requiresOperatorReview, true);
  assert.equal(body.reconciliationStatus, "REQUIRED");
  assert.equal(body.state, "PENDING");
  const persisted = h.calls.find((call) => call.url.includes("/control_plane_mark_billing_reconciliation_required"));
  assert.ok(persisted);
  assert.equal(JSON.parse(persisted.init.body).p_charge_id, charge.chargeId);
  assert.equal(JSON.parse(persisted.init.body).p_reason, "SHOPIFY_TRANSPORT_OUTCOME_UNKNOWN");
  assert.equal(h.calls.some((call) => call.url.includes("/control_plane_record_billing_usage_result")), false);
});

test("does not pretend reconciliation is persisted when the database RPC fails", async () => {
  const h = harness({ claim: { ...charge, attempt: 5 }, failShopify: true, failReconciliation: true });
  const handler = createShopifyUsageBillingHandler({ env, fetchImpl: h.fetchImpl, logger: quiet });
  const result = await handler(request());
  const body = await result.json();
  assert.equal(result.status, 503);
  assert.equal(body.reconciliationPersisted, false);
  assert.equal(body.requiresOperatorReview, true);
});


test("billing execution is attached to the existing recovery scheduler in an inactive staging-only candidate", () => {
  const fixture = JSON.parse(readFileSync("n8n/fixtures/henvalt-recovery-active-2026-11-21.sanitized.json", "utf8"));
  const manifest = JSON.parse(readFileSync("n8n/shopify-recovery-replay-graph-patch.json", "utf8"));
  const normalizer = readFileSync("n8n/shopify-replay-claim-normalizer-node-candidate.js", "utf8");
  const result = buildRecoveryBillingCandidate(fixture.workflow, manifest, normalizer);
  const workflow = result.workflow;
  const byName = new Map(workflow.nodes.map((node) => [node.name, node]));
  const discovery = byName.get("Find Shopify Usage Billing Shops");
  const call = byName.get("Call Shopify Usage Billing Worker");

  assert.equal(workflow.id, "00000000-0000-4000-8000-999999999995");
  assert.equal(workflow.name, "HENVALT_RECOVERY_CANDIDATE_BILLING_STAGING_ONLY");
  assert.equal(workflow.active, false);
  assert.equal(workflow.settings.availableInMCP, false);
  assert.equal(workflow.nodes.length, 62);
  assert.equal(result.audit.workflow_count, 3);
  assert.equal(result.audit.maximum_shops_per_tick, 10);
  assert.ok(discovery.parameters.query.includes("rl.entry_type = 'RECOVERY'"));
  assert.ok(discovery.parameters.query.includes("rl.attribution_confidence = 'CONFIRMED'"));
  assert.ok(discovery.parameters.query.includes("buc.attempt_count < 5"));
  assert.ok(discovery.parameters.query.includes("ba.test_mode = true"));
  assert.ok(discovery.parameters.query.includes("reconciliation_status IN ('NONE','NOT_FOUND_CONFIRMED')"));
  assert.ok(discovery.parameters.query.includes("LIMIT 10"));
  assert.doesNotMatch(discovery.parameters.query, /\b(?:INSERT|UPDATE|DELETE|MERGE)\b/i);
  assert.equal(call.parameters.url, "https://supabase-staging.invalid/functions/v1/henvalt-shopify-usage-billing");
  assert.equal(call.parameters.authentication, "genericCredentialType");
  assert.equal(call.parameters.genericAuthType, "httpHeaderAuth");
  assert.equal(call.parameters.jsonBody, "={{ { shop: $json.shop_domain } }}");
  assert.equal(call.parameters.options.timeout, 30000);
  assert.equal(call.onError, "continueRegularOutput");
  assert.equal(call.credentials, undefined);

  const scheduled = workflow.connections["Every Minute"].main[0].map((item) => item.node);
  assert.ok(scheduled.includes("Reconcile Deferred Payment Webhooks"));
  assert.ok(scheduled.includes("Find Shopify Usage Billing Shops"));
  assert.equal(workflow.connections["Find Shopify Usage Billing Shops"].main[0][0].node, "Call Shopify Usage Billing Worker");
  assert.equal(workflow.connections["Call Shopify Usage Billing Worker"].main[0].length, 0);
  assert.equal(result.audit.worker_endpoint_is_staging_placeholder, true);
  assert.equal(JSON.stringify(workflow).includes("ocyplckdojdubyrsxcxa.supabase.co"), false);
  assert.equal(JSON.stringify(workflow).includes("service-role-test-secret"), false);
});

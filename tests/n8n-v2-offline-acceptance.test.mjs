import test from "node:test";
import assert from "node:assert/strict";
import { createV2DeliveryRuntime } from "../n8n/v2-delivery-runtime.mjs";
import { createV2RecoveryRuntime } from "../n8n/v2-recovery-runtime.mjs";

const checkoutId = "11111111-1111-4111-8111-111111111111";
const checkoutLease = "22222222-2222-4222-8222-222222222222";
const pixelId = "33333333-3333-4333-8333-333333333333";
const pixelLease = "44444444-4444-4444-8444-444444444444";

function makeRuntime(fetchImpl) {
  const delivery = createV2DeliveryRuntime({
    supabaseUrl: "https://project.supabase.co",
    checkoutDeliveryAuthToken: "c".repeat(32),
    pixelDeliveryAuthToken: "p".repeat(32),
    fetchImpl,
  });
  return createV2RecoveryRuntime({
    supabaseUrl: "https://project.supabase.co",
    serviceRoleKey: "s".repeat(40),
    handoff: delivery.handleClaim,
    fetchImpl,
  });
}

function claimResponse(workType, workId, leaseId) {
  return new Response(JSON.stringify({
    accepted: true,
    claimed: 1,
    items: [{ work_type: workType, work_id: workId, lease_id: leaseId }],
  }), { status: 200 });
}

function rpcSuccess(body = { accepted: true }) {
  return new Response(JSON.stringify(body), { status: 200 });
}

const cases = [
  { name: "unauthorized delivery credential", status: 401, expected: "DEFERRED" },
  { name: "forbidden delivery credential", status: 403, expected: "DEFERRED" },
  { name: "consent, sender or eligibility preflight rejection", status: 409, expected: "DEFERRED" },
  { name: "provider or edge throttling", status: 429, expected: "DEFERRED" },
  { name: "edge unavailable before confirmed handoff", status: 503, expected: "DEFERRED" },
  { name: "permanent malformed opaque request", status: 400, expected: "TERMINAL" },
  { name: "missing V2 route or resource", status: 404, expected: "DEFERRED" },
  { name: "retired V2 route", status: 410, expected: "DEFERRED" },
  { name: "unprocessable work resource", status: 422, expected: "TERMINAL" },
  { name: "provider definite rejection already recorded", status: 502, body: { accepted: false, error: "provider_submission_rejected" }, expected: "TERMINAL" },
  { name: "provider submission accepted but reconciliation pending", status: 202, body: { accepted: true, status: "ambiguous_provider_submission" }, expected: "HANDOFF_ACCEPTED" },
];

for (const scenario of cases) {
  test(`offline Recovery→Delivery acceptance: ${scenario.name}`, async () => {
    const calls = [];
    const finished = [];
    const fetchImpl = async (url, init) => {
      const body = init.body ? JSON.parse(init.body) : null;
      calls.push({ url, init, body });
      if (url.includes("/rest/v1/rpc/claim_shopify_recovery_work_v2")) {
        return claimResponse("CHECKOUT_INTERVENTION", checkoutId, checkoutLease);
      }
      if (url.includes("/functions/v1/henvalt-shopify-contact-delivery-v2")) {
        assert.deepEqual(body, { intervention_id: checkoutId });
        return new Response(JSON.stringify(scenario.body ?? { error: "blocked" }), { status: scenario.status });
      }
      if (url.includes("/rest/v1/rpc/finish_shopify_recovery_work_claim_v2")) {
        finished.push(body);
        return rpcSuccess({ finished: true, outcome: body.p_outcome });
      }
      if (url.includes("/rest/v1/rpc/")) return rpcSuccess();
      throw new Error("unexpected_network_target");
    };
    const runtime = makeRuntime(fetchImpl);
    const result = await runtime.runTick({ workerId: "worker-acceptance-01" });
    assert.equal(result.summary.outcomes[0].outcome, scenario.expected);
    assert.equal(finished.length, 1);
    assert.equal(finished[0].p_outcome, scenario.expected);
    assert.equal(result.summary.lease_finish_unconfirmed, 0);
    assert.equal(calls.some(call => call.url.includes("api.mailersend.com")), false);
    assert.equal(JSON.stringify(result).includes("recipient@example.com"), false);
    assert.equal(JSON.stringify(result).includes("Bearer "), false);
  });
}

test("offline Recovery→Delivery acceptance: malformed Edge JSON safely defers and finishes the lease", async () => {
  const finished = [];
  const fetchImpl = async (url, init) => {
    if (url.includes("/rest/v1/rpc/claim_shopify_recovery_work_v2")) {
      return claimResponse("PIXEL_OPPORTUNITY", pixelId, pixelLease);
    }
    if (url.includes("/functions/v1/henvalt-shopify-pixel-delivery-v2")) {
      return new Response("not-json", { status: 202 });
    }
    if (url.includes("/rest/v1/rpc/finish_shopify_recovery_work_claim_v2")) {
      finished.push(JSON.parse(init.body));
      return rpcSuccess({ finished: true, outcome: JSON.parse(init.body).p_outcome });
    }
    if (url.includes("/rest/v1/rpc/")) return rpcSuccess();
    throw new Error("unexpected_network_target");
  };
  const result = await makeRuntime(fetchImpl).runTick({ workerId: "worker-acceptance-02" });
  assert.equal(result.summary.outcomes[0].outcome, "DEFERRED");
  assert.equal(finished[0].p_outcome, "DEFERRED");
  assert.equal(finished[0].p_retry_after, "3600 seconds");
});

test("offline Recovery→Delivery acceptance: transport timeout does not expose raw error or call provider", async () => {
  const finished = [];
  const fetchImpl = async (url, init) => {
    if (url.includes("/rest/v1/rpc/claim_shopify_recovery_work_v2")) {
      return claimResponse("PIXEL_OPPORTUNITY", pixelId, pixelLease);
    }
    if (url.includes("/functions/v1/henvalt-shopify-pixel-delivery-v2")) {
      throw new Error("timeout recipient@example.com provider-secret");
    }
    if (url.includes("/rest/v1/rpc/finish_shopify_recovery_work_claim_v2")) {
      finished.push(JSON.parse(init.body));
      return rpcSuccess({ finished: true, outcome: JSON.parse(init.body).p_outcome });
    }
    if (url.includes("/rest/v1/rpc/")) return rpcSuccess();
    throw new Error("unexpected_network_target");
  };
  const result = await makeRuntime(fetchImpl).runTick({ workerId: "worker-acceptance-03" });
  assert.equal(result.summary.outcomes[0].outcome, "DEFERRED");
  assert.equal(result.summary.outcomes[0].reason_code, "handoff_transport_ambiguous");
  assert.equal(finished[0].p_outcome, "DEFERRED");
  assert.equal(JSON.stringify(result).includes("recipient@example.com"), false);
  assert.equal(JSON.stringify(result).includes("provider-secret"), false);
});

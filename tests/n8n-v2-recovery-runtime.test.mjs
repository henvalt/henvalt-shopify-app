import test from "node:test";
import assert from "node:assert/strict";
import { createV2DeliveryRuntime } from "../n8n/v2-delivery-runtime.mjs";
import { createV2RecoveryRuntime } from "../n8n/v2-recovery-runtime.mjs";

function compose(fakeFetch) {
  const delivery = createV2DeliveryRuntime({
    supabaseUrl: "https://project.supabase.co",
    checkoutDeliveryAuthToken: "c".repeat(32),
    pixelDeliveryAuthToken: "p".repeat(32),
    fetchImpl: fakeFetch,
  });
  const recovery = createV2RecoveryRuntime({
    supabaseUrl: "https://project.supabase.co",
    serviceRoleKey: "s".repeat(40),
    handoff: delivery.handleClaim,
    fetchImpl: fakeFetch,
  });
  return recovery;
}

test("three-workflow runtime composes Recovery → Delivery and finishes checkout lease", async () => {
  const calls = [];
  const fakeFetch = async (url, init) => {
    const body = init.body ? JSON.parse(init.body) : null;
    calls.push({ url, init, body });
    if (url.includes("/rest/v1/rpc/claim_shopify_recovery_work_v2")) {
      return new Response(JSON.stringify({
        accepted: true,
        claimed: 1,
        items: [{
          work_type: "CHECKOUT_INTERVENTION",
          work_id: "11111111-1111-4111-8111-111111111111",
          lease_id: "22222222-2222-4222-8222-222222222222",
          tenant_id: "must-not-forward",
          shopify_connection_id: "must-not-forward",
        }],
      }), { status: 200 });
    }
    if (url.includes("/functions/v1/henvalt-shopify-contact-delivery-v2")) {
      assert.deepEqual(body, { intervention_id: "11111111-1111-4111-8111-111111111111" });
      assert.equal(init.headers.authorization, "Bearer " + "c".repeat(32));
      return new Response(JSON.stringify({ accepted: true, status: "submitted" }), { status: 202 });
    }
    if (url.includes("/rest/v1/rpc/finish_shopify_recovery_work_claim_v2")) {
      assert.equal(body.p_outcome, "HANDOFF_ACCEPTED");
      assert.equal(body.p_retry_after, "0 seconds");
      return new Response(JSON.stringify({ finished: true, outcome: "HANDOFF_ACCEPTED" }), { status: 200 });
    }
    if (url.includes("/rest/v1/rpc/")) return new Response(JSON.stringify({ accepted: true }), { status: 200 });
    throw new Error("unexpected_network_target");
  };
  const runtime = compose(fakeFetch);
  const result = await runtime.runTick({ workerId: "worker-v2-01" });
  assert.equal(result.accepted, true);
  assert.equal(result.summary.handoff_accepted, 1);
  assert.equal(result.summary.lease_finish_unconfirmed, 0);
  assert.equal(result.provider_called_by_orchestrator, false);
  assert.equal(calls.some(x => x.url.includes("api.mailersend.com")), false);
  assert.equal(JSON.stringify(result).includes("recipient_email_returned"), false);
  assert.equal(calls.some(x => x.url.includes("henvalt-shopify-pixel-delivery-v2")), false);
  assert.equal(calls.filter(x => x.url.includes("/rest/v1/rpc/")).length, 7);
  const handoff = calls.find(x => x.url.includes("/functions/v1/henvalt-shopify-contact-delivery-v2"));
  assert.equal(JSON.stringify(handoff.body).includes("must-not-forward"), false);
  assert.equal(JSON.stringify(result).includes("must-not-forward"), false);
  assert.equal(JSON.stringify(result).includes("recipient@example.com"), false);
});

test("ambiguous 202 is returned by Delivery, then Recovery completes the lease exactly once", async () => {
  const calls = [];
  const fakeFetch = async (url, init) => {
    const body = init.body ? JSON.parse(init.body) : null;
    calls.push({ url, body });
    if (url.includes("/rest/v1/rpc/claim_shopify_recovery_work_v2")) {
      return new Response(JSON.stringify({
        accepted: true,
        items: [{
          work_type: "PIXEL_OPPORTUNITY",
          work_id: "33333333-3333-4333-8333-333333333333",
          lease_id: "44444444-4444-4444-8444-444444444444",
        }],
      }), { status: 200 });
    }
    if (url.includes("/functions/v1/henvalt-shopify-pixel-delivery-v2")) {
      assert.equal(init.headers.authorization, "Bearer " + "p".repeat(32));
      return new Response(JSON.stringify({
        accepted: true,
        status: "ambiguous_provider_submission",
        recipient_email_returned: false,
      }), { status: 202 });
    }
    if (url.includes("/rest/v1/rpc/finish_shopify_recovery_work_claim_v2")) {
      assert.equal(body.p_outcome, "HANDOFF_ACCEPTED");
      return new Response(JSON.stringify({ finished: true, outcome: "HANDOFF_ACCEPTED" }), { status: 200 });
    }
    if (url.includes("/rest/v1/rpc/")) return new Response(JSON.stringify({ accepted: true }), { status: 200 });
    throw new Error("unexpected_network_target");
  };
  const runtime = compose(fakeFetch);
  const result = await runtime.runTick({ workerId: "worker-v2-02" });
  assert.equal(result.summary.handoff_accepted, 1);
  assert.equal(result.summary.deferred, 0);
  assert.equal(result.summary.lease_finish_unconfirmed, 0);
  assert.equal(calls.filter(x => x.url.includes("/functions/v1/henvalt-shopify-pixel-delivery-v2")).length, 1);
  assert.equal(calls.some(x => x.url.includes("api.mailersend.com")), false);
});

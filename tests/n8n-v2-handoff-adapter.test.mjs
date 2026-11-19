import test from "node:test";
import assert from "node:assert/strict";
import {
  classifyHandoffResponse,
  createV2HandoffAdapter,
  validateClaim,
} from "../n8n/v2-handoff-adapter.mjs";

const checkout = {
  work_type: "CHECKOUT_INTERVENTION",
  work_id: "11111111-1111-4111-8111-111111111111",
  lease_id: "22222222-2222-4222-8222-222222222222",
  worker_id: "worker-v2-01",
  correlation_id: "corr-123",
};
const pixel = {
  ...checkout,
  work_type: "PIXEL_OPPORTUNITY",
  work_id: "33333333-3333-4333-8333-333333333333",
};

test("claim validator rejects unknown work, malformed IDs and unsafe worker metadata", () => {
  assert.equal(validateClaim(checkout).endpoint, "henvalt-shopify-contact-delivery-v2");
  assert.equal(validateClaim(pixel).endpoint, "henvalt-shopify-pixel-delivery-v2");
  assert.throws(() => validateClaim({ ...checkout, work_type: "OTHER" }), /invalid_claim/);
  assert.throws(() => validateClaim({ ...checkout, work_id: "not-a-uuid" }), /invalid_claim/);
  assert.throws(() => validateClaim({ ...checkout, worker_id: "x\nsecret" }), /invalid_claim/);
});

test("accepted ambiguous handoffs complete; security responses defer", () => {
  assert.equal(classifyHandoffResponse(202, { accepted: true, status: "submitted" }).outcome, "HANDOFF_ACCEPTED");
  assert.equal(classifyHandoffResponse(202, { accepted: true, status: "ambiguous_provider_submission" }).outcome, "HANDOFF_ACCEPTED");
  assert.equal(classifyHandoffResponse(202, { accepted: true, status: "provider_accepted_record_pending" }).outcome, "HANDOFF_ACCEPTED");
  assert.equal(classifyHandoffResponse(502, { accepted: false, error: "provider_submission_rejected" }).outcome, "TERMINAL");
  for (const status of [401, 403, 409, 429, 500, 503]) {
    assert.equal(classifyHandoffResponse(status, {}).outcome, "DEFERRED");
  }
  assert.equal(classifyHandoffResponse(401, {}).reason, "delivery_auth_incident");
  assert.equal(classifyHandoffResponse(409, {}).reason, "delivery_preflight_or_eligibility_review");
  assert.equal(classifyHandoffResponse(429, {}).reason, "handoff_rate_limited");
  for (const status of [400, 422]) {
    assert.equal(classifyHandoffResponse(status, {}).outcome, "TERMINAL");
  }
  for (const status of [404, 410]) {
    assert.equal(classifyHandoffResponse(status, {}).outcome, "DEFERRED");
  }
  assert.equal(classifyHandoffResponse(200, {}).outcome, "DEFERRED");
});

test("checkout and pixel dispatch use distinct opaque-only bodies", async () => {
  const requests = [];
  const adapter = createV2HandoffAdapter({
    supabaseUrl: "https://project.supabase.co/",
    checkoutBearerToken: "c".repeat(32),
    pixelBearerToken: "p".repeat(32),
    fetchImpl: async (url, init) => {
      requests.push({ url, init, body: JSON.parse(init.body) });
      return new Response(JSON.stringify({ accepted: true, status: "submitted" }), { status: 202 });
    },
  });
  const a = await adapter(checkout);
  const b = await adapter(pixel);
  assert.match(requests[0].url, /henvalt-shopify-contact-delivery-v2$/);
  assert.deepEqual(requests[0].body, { intervention_id: checkout.work_id });
  assert.match(requests[1].url, /henvalt-shopify-pixel-delivery-v2$/);
  assert.deepEqual(requests[1].body, { opportunity_id: pixel.work_id });
  for (const request of requests) {
    assert.deepEqual(Object.keys(request.body).sort(), [request.url.includes("contact") ? "intervention_id" : "opportunity_id"]);
    assert.equal(request.init.headers.authorization, request.url.includes("contact") ? "Bearer " + "c".repeat(32) : "Bearer " + "p".repeat(32));
  }
  assert.equal(a.outcome, "HANDOFF_ACCEPTED");
  assert.equal(a.http_status, 202);
  assert.equal(b.outcome, "HANDOFF_ACCEPTED");
  assert.equal(b.http_status, 202);
  assert.equal(JSON.stringify([a, b]).includes("Bearer"), false);
});

test("transport errors and malformed provider responses defer without exposing exception data", async () => {
  const adapter = createV2HandoffAdapter({
    supabaseUrl: "https://project.supabase.co",
    checkoutBearerToken: "c".repeat(32),
    pixelBearerToken: "p".repeat(32),
    fetchImpl: async () => { throw new Error("secret recipient@example.com"); },
  });
  const result = await adapter(checkout);
  assert.equal(result.outcome, "DEFERRED");
  assert.equal(result.reason, "handoff_transport_ambiguous");
  assert.equal(JSON.stringify(result).includes("recipient@example.com"), false);
  assert.equal(result.retry_after_seconds, 3600);
  assert.equal(result.http_status, null);
});

test("adapter refuses non-HTTPS endpoints or missing delivery credentials", () => {
  assert.throws(() => createV2HandoffAdapter({
    supabaseUrl: "http://project.supabase.co",
    checkoutBearerToken: "c".repeat(32),
    pixelBearerToken: "p".repeat(32),
  }), /invalid_adapter_configuration/);
  assert.throws(() => createV2HandoffAdapter({
    supabaseUrl: "https://attacker.example",
    checkoutBearerToken: "c".repeat(32),
    pixelBearerToken: "p".repeat(32),
  }), /invalid_adapter_configuration/);
  assert.throws(() => createV2HandoffAdapter({
    supabaseUrl: "https://project.supabase.co:8443",
    checkoutBearerToken: "c".repeat(32),
    pixelBearerToken: "p".repeat(32),
  }), /invalid_adapter_configuration/);
  assert.throws(() => createV2HandoffAdapter({
    supabaseUrl: "https://project.supabase.co",
    checkoutBearerToken: "c".repeat(32),
  }), /invalid_adapter_configuration/);
});

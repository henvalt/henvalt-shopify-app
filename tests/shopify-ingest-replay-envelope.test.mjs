import test from "node:test";
import assert from "node:assert/strict";
import { buildShopifyReplayEnvelope } from "../n8n/shopify-ingest-replay-envelope-candidate.mjs";

const JOB = "11111111-1111-4111-8111-111111111111";
const LEASE = "22222222-2222-4222-8222-222222222222";
const WEBHOOK = "33333333-3333-4333-8333-333333333333";
const TENANT = "44444444-4444-4444-8444-444444444444";
const CORR = "55555555-5555-4555-8555-555555555555";
const NOW = Date.parse("2026-11-21T17:00:00.000Z");
const claim = { job_id: JOB, worker_id: "recovery:42", lease_id: LEASE };
const loaded = (overrides = {}) => ({
  job_id: JOB, webhook_id: WEBHOOK, tenant_id: TENANT,
  source_event_id: "delivery-123", topic: "checkouts/update",
  payload: { id: 9001, email: "buyer@example.test", total_price: "42.00" },
  metadata: {
    ingress_hmac_verified: true, shop_domain: "demo-shop.myshopify.com",
    shopify_webhook_id: "delivery-123", shopify_api_version: "2026-10",
    shopify_triggered_at: "2026-11-21T16:59:00Z",
  },
  processing_status: "PROCESSING", webhook_processed: false,
  correlation_id: CORR, lease_expires_at: "2026-11-21T17:03:00.000Z",
  ...overrides,
});

test("constructs the normalizer-compatible envelope from a valid leased row", () => {
  const result = buildShopifyReplayEnvelope(claim, loaded(), NOW);
  assert.equal(result.ok, true);
  assert.equal(result.envelope.body.event_id, "delivery-123");
  assert.equal(result.envelope.headers["x-shopify-webhook-id"], "delivery-123");
  assert.equal(result.envelope.headers["x-shopify-event-id"], undefined);
  assert.equal(result.envelope.replay_context.tenant_id, TENANT);
  assert.deepEqual(result.envelope.query, {});
  assert.equal(result.envelope.replay_context.lease_id, LEASE);
});

test("requires exact job, worker, lease, tenant and webhook identities", () => {
  const result = buildShopifyReplayEnvelope(
    { ...claim, job_id: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa" },
    loaded(), NOW,
  );
  assert.equal(result.ok, false);
  assert.match(result.reason, /JOB_ID_MISMATCH/);
});

test("rejects untrusted, malformed, or missing ingress attestation and delivery identity", () => {
  for (const overrides of [
    { metadata: { ...loaded().metadata, ingress_hmac_verified: false } },
    { source_event_id: "" },
    { metadata: { ...loaded().metadata, shopify_webhook_id: "other-delivery" } },
    { metadata: { ...loaded().metadata, shop_domain: "attacker.example" } },
    { payload: [] },
  ]) {
    assert.equal(buildShopifyReplayEnvelope(claim, loaded(overrides), NOW).ok, false);
  }
});

test("rejects expired leases, already processed events and invalid correlation IDs", () => {
  assert.match(buildShopifyReplayEnvelope(claim, loaded({
    lease_expires_at: "2026-11-21T16:59:59.000Z",
  }), NOW).reason, /LEASE_EXPIRED/);
  assert.match(buildShopifyReplayEnvelope(claim, loaded({
    webhook_processed: true, processing_status: "PROCESSED",
  }), NOW).reason, /WEBHOOK_ALREADY_PROCESSED/);
  assert.match(buildShopifyReplayEnvelope(claim, loaded({
    correlation_id: "not-a-uuid",
  }), NOW).reason, /CORRELATION_ID_INVALID/);
});

test("does not mutate or leak lease fields into the Shopify payload", () => {
  const original = loaded();
  const result = buildShopifyReplayEnvelope(claim, original, NOW);
  assert.equal(original.payload.event_id, undefined);
  assert.equal(result.envelope.body.email, "buyer@example.test");
  assert.equal(result.envelope.body.tenant_id, undefined);
  assert.equal(result.envelope.replay_context.ingress_hmac_verified, true);
});

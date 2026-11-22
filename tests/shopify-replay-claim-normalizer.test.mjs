import test from "node:test";
import assert from "node:assert/strict";
import { normalizeShopifyReplayClaim } from "../n8n/shopify-replay-claim-normalizer-candidate.mjs";

const JOB_ID = "11111111-1111-4111-8111-111111111111";
const LEASE_ID = "22222222-2222-4222-8222-222222222222";
const WEBHOOK_ID = "33333333-3333-4333-8333-333333333333";
const EXPIRY = "2099-11-21T23:00:00.000Z";
const WORKER = "henvalt_recovery:execution-42";

function row(overrides = {}) {
  return {
    id: JOB_ID,
    job_type: "process_shopify_webhook",
    lease_id: LEASE_ID,
    lease_expires_at: EXPIRY,
    locked_by: WORKER,
    payload: { webhook_id: WEBHOOK_ID, tenant_id: "must-not-leave-normalizer" },
    ...overrides,
  };
}

test("empty claim result is distinguishable from a malformed claimed row", () => {
  const result = normalizeShopifyReplayClaim({}, WORKER);
  assert.equal(result.claim_row_present, false);
  assert.equal(result.guard_valid, false);
  assert.equal(result.has_replay_job, false);
  assert.equal(result.guard_reason, "EMPTY_CLAIM");
});

test("valid claim row maps id to job_id and preserves the lease tuple", () => {
  const result = normalizeShopifyReplayClaim(row(), WORKER);
  assert.deepEqual(result, {
    claim_row_present: true,
    guard_valid: true,
    has_replay_job: true,
    job_id: JOB_ID,
    worker_id: WORKER,
    lease_id: LEASE_ID,
    lease_expires_at: EXPIRY,
    webhook_id: WEBHOOK_ID,
  });
});

test("JSON-string payload is parsed but raw payload and tenant data are not forwarded", () => {
  const result = normalizeShopifyReplayClaim(
    row({ payload: JSON.stringify({ webhook_id: WEBHOOK_ID, tenant_id: "private" }) }),
    WORKER,
  );
  assert.equal(result.guard_valid, true);
  assert.equal("payload" in result, false);
  assert.equal("tenant_id" in result, false);
});

test("unknown job type is rejected rather than entering the intervention branch", () => {
  const result = normalizeShopifyReplayClaim(row({ job_type: "execute_intervention" }), WORKER);
  assert.equal(result.claim_row_present, true);
  assert.equal(result.guard_valid, false);
  assert.equal(result.has_replay_job, false);
  assert.match(result.guard_reason, /UNEXPECTED_JOB_TYPE/);
});

test("invalid job, lease, webhook UUIDs and missing expiry fail closed", () => {
  const result = normalizeShopifyReplayClaim(row({
    id: "not-a-uuid",
    lease_id: "bad-lease",
    lease_expires_at: null,
    payload: { webhook_id: "bad-webhook" },
  }), WORKER);
  assert.equal(result.guard_valid, false);
  assert.match(result.guard_reason, /INVALID_JOB_ID/);
  assert.match(result.guard_reason, /INVALID_LEASE_ID/);
  assert.match(result.guard_reason, /INVALID_WEBHOOK_ID/);
  assert.match(result.guard_reason, /INVALID_LEASE_EXPIRY/);
});

test("malformed JSON payload and blank worker identity are rejected", () => {
  const result = normalizeShopifyReplayClaim(row({ payload: "{broken" }), "   ");
  assert.equal(result.guard_valid, false);
  assert.match(result.guard_reason, /MISSING_WORKER_ID/);
  assert.match(result.guard_reason, /INVALID_WEBHOOK_ID/);
});

test("normalizer does not expose raw payload or unrelated claim columns", () => {
  const result = normalizeShopifyReplayClaim(row({
    tenant_id: "tenant-raw",
    locked_by: WORKER,
    attempts: 9,
    payload: { webhook_id: WEBHOOK_ID, customer_email: "private@example.test" },
  }), WORKER);
  const keys = Object.keys(result).sort();
  assert.deepEqual(keys, [
    "claim_row_present",
    "guard_valid",
    "has_replay_job",
    "job_id",
    "lease_expires_at",
    "lease_id",
    "webhook_id",
    "worker_id",
  ].sort());
});


test("claim is rejected if the database owner differs from the recovery worker", () => {
  const result = normalizeShopifyReplayClaim(row({ locked_by: "different-worker" }), WORKER);
  assert.equal(result.guard_valid, false);
  assert.match(result.guard_reason, /WORKER_MISMATCH/);
});

test("expired lease is rejected even if its UUID and worker are otherwise valid", () => {
  const result = normalizeShopifyReplayClaim(row({
    lease_expires_at: "2020-01-01T00:00:00.000Z"
  }), WORKER);
  assert.equal(result.guard_valid, false);
  assert.match(result.guard_reason, /INVALID_LEASE_EXPIRY/);
});

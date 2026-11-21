import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const source = readFileSync(
  "n8n/shopify-replay-claim-normalizer-node-candidate.js",
  "utf8",
);
const helper = readFileSync(
  "n8n/shopify-replay-claim-normalizer-candidate.mjs",
  "utf8",
);
const manifest = JSON.parse(readFileSync(
  "n8n/shopify-recovery-replay-graph-patch.json",
  "utf8",
));

test("replay claim Code node is self-contained and has no module import dependency", () => {
  assert.doesNotMatch(source, /^\s*(import|export)\s/m);
  assert.match(source, /const workerId = \$\("Init Worker"\)\.first\(\)\.json\.worker_id/);
  assert.match(source, /return \{ json: normalizeShopifyReplayClaim\(\$json, workerId\) \}/);
  const node = manifest.nodes_to_add.find((item) => item.name === "Normalize Shopify Replay Claim");
  assert.equal(node.code_ref, "n8n/shopify-replay-claim-normalizer-node-candidate.js");
  assert.equal(node.code_execution, "inline self-contained Code node source; no module imports");
});

test("inline Code node preserves strict UUID, job-type and lease-expiry validation", () => {
  for (const pattern of [
    /process_shopify_webhook/,
    /INVALID_JOB_ID/,
    /INVALID_LEASE_ID/,
    /INVALID_WEBHOOK_ID/,
    /INVALID_LEASE_EXPIRY/,
    /EMPTY_CLAIM/,
  ]) {
    assert.match(source, pattern);
  }
  assert.match(source, /claim_row_present: true, guard_valid: false/);
  assert.match(source, /claim_row_present: false, guard_valid: false/);
});

test("inline Code node emits only the normalized lease tuple and webhook ID", () => {
  assert.match(source, /job_id: jobId/);
  assert.match(source, /worker_id: normalizedWorkerId/);
  assert.match(source, /lease_id: leaseId/);
  assert.match(source, /webhook_id: webhookId/);
  assert.doesNotMatch(source, /return \{ json: Object\.assign/);
  assert.doesNotMatch(source, /payload:\s*payload/);
  assert.doesNotMatch(source, /customer|email|recipient|raw_body/i);
});

test("inline node validation remains aligned with the pure tested helper", () => {
  for (const token of [
    "UNEXPECTED_JOB_TYPE",
    "INVALID_JOB_ID",
    "INVALID_LEASE_ID",
    "MISSING_WORKER_ID",
    "INVALID_WEBHOOK_ID",
    "INVALID_LEASE_EXPIRY",
    "EMPTY_CLAIM",
  ]) {
    assert.ok(source.includes(token), "inline source missing " + token);
    assert.ok(helper.includes(token), "pure helper missing " + token);
  }
});


test("inline Code node executes against actual background_jobs claim-row shape", () => {
  const runNode = (row, workerId = "replay-worker-1") => {
    const lookup = (name) => {
      assert.equal(name, "Init Worker");
      return { first: () => ({ json: { worker_id: workerId } }) };
    };
    return new Function("$", "$json", source)(lookup, row).json;
  };
  const claim = {
    id: "11111111-1111-4111-8111-111111111111",
    job_type: "process_shopify_webhook",
    payload: { webhook_id: "22222222-2222-4222-8222-222222222222" },
    lease_id: "33333333-3333-4333-8333-333333333333",
    lease_expires_at: "2026-11-21T18:00:00.000Z",
    tenant_id: "44444444-4444-4444-8444-444444444444",
    locked_by: "replay-worker-1",
    customer_email: "must-not-escape@example.invalid"
  };
  const result = runNode(claim);
  assert.deepEqual(Object.keys(result).sort(), [
    "claim_row_present", "guard_valid", "has_replay_job", "job_id",
    "worker_id", "lease_id", "lease_expires_at", "webhook_id"
  ].sort());
  assert.equal(result.guard_valid, true);
  assert.equal(result.job_id, claim.id);
  assert.equal(result.webhook_id, claim.payload.webhook_id);
  assert.equal(result.worker_id, "replay-worker-1");
  assert.equal("tenant_id" in result, false);
  assert.equal("customer_email" in result, false);
});

test("inline Code node treats empty claims normally and malformed present claims as fail-closed", () => {
  const runNode = (row) => new Function(
    "$", "$json", source
  )((name) => ({ first: () => ({ json: { worker_id: "worker" } }) }), row).json;
  assert.equal(runNode({}).guard_reason, "EMPTY_CLAIM");
  const malformed = runNode({
    id: "not-a-uuid",
    job_type: "execute_intervention",
    payload: "{bad json",
    lease_id: "not-a-uuid",
    lease_expires_at: "not-a-date"
  });
  assert.equal(malformed.claim_row_present, true);
  assert.equal(malformed.guard_valid, false);
  assert.match(malformed.guard_reason, /UNEXPECTED_JOB_TYPE/);
  assert.match(malformed.guard_reason, /INVALID_JOB_ID/);
  assert.match(malformed.guard_reason, /INVALID_LEASE_ID/);
  assert.match(malformed.guard_reason, /INVALID_WEBHOOK_ID/);
  assert.match(malformed.guard_reason, /INVALID_LEASE_EXPIRY/);
});

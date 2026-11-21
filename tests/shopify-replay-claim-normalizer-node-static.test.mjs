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

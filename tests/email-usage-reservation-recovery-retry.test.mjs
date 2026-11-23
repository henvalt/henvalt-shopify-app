import test from "node:test";
import assert from "node:assert/strict";
import vm from "node:vm";
import { readFileSync } from "node:fs";

const fixture = JSON.parse(readFileSync(
  new URL("../n8n/fixtures/henvalt-recovery-active-2026-11-21.sanitized.json", import.meta.url),
  "utf8",
));
const classifier = fixture.workflow.nodes.find(
  (node) => node.name === "Classify Delivery Failure",
)?.parameters?.jsCode;
assert.equal(typeof classifier, "string", "pinned active recovery failure classifier must exist");

function classify(response) {
  const normalize = {
    intervention_id: "11111111-1111-4111-8111-111111111111",
    job_id: "22222222-2222-4222-8222-222222222222",
    worker_id: "quota-retry-test",
  };
  const run = vm.runInNewContext(`(function ($json, $) {\n${classifier}\n})`, {});
  return run(response, (name) => ({
    item: { json: name === "Normalize & Guard" ? normalize : {} },
  }));
}

test("ambiguous provider outcomes are not automatically requeued by recovery", () => {
  for (const status of ["UNKNOWN", "ACCEPTED", "DELIVERED"]) {
    const result = classify({
      body: { state: status, failure_category: "PROVIDER_TRANSIENT" },
      statusCode: status === "UNKNOWN" ? 502 : 202,
    });
    assert.equal(result.json.retryable, false, `${status} must not trigger a retry`);
    assert.equal(result.json.final_status, "FAILED");
  }
});

test("only pre-send configuration rejections are automatically requeued", () => {
  for (const reason of ["SENDER_IDENTITY_NOT_CONFIGURED", "EMAIL_PROVIDER_NOT_CONFIGURED"]) {
    const result = classify({
      body: { state: "REJECTED", failure_category: reason },
      statusCode: 409,
    });
    assert.equal(result.json.retryable, true);
    assert.equal(result.json.final_status, "READY");
  }
  const other = classify({
    body: { state: "REJECTED", failure_category: "CONSENT_REVOKED" },
    statusCode: 409,
  });
  assert.equal(other.json.retryable, false);
  assert.equal(other.json.final_status, "SKIPPED");
});

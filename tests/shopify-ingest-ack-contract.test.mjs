import test from "node:test";
import assert from "node:assert/strict";
import { SHOPIFY_INGEST_ACK_CONTRACT as c } from "../cloudflare/shopify-ingest-ack-contract.mjs";

test("Shopify webhook response is delayed until durable raw ingest classification", () => {
  assert.equal(c.webhookResponseMode, "responseNode");
  assert.equal(c.afterNode, "Classify Result");
  assert.equal(c.beforeNode, "Should Process?");
  assert.equal(c.acknowledgeOnlyAfter, "ingest_raw_webhook_v2");
  assert.equal(c.continueExecutionAfterResponse, true);
});

test("acknowledgement contract returns retryable status for ambiguous or transient ingest failure", () => {
  assert.deepEqual(c.acceptedStatuses, [200]);
  assert.deepEqual(c.retryableStatuses, [503]);
  assert.deepEqual(c.rejectStatuses, [401, 404, 422]);
  assert.equal(c.responseCodeExpression, "={{ $json.__http }}");
  assert.equal(c.responseBodyExpression, "={{ $json.__body }}");
});

test("acknowledgement contract is immutable", () => {
  assert.equal(Object.isFrozen(c), true);
  assert.equal(Object.isFrozen(c.acceptedStatuses), true);
});

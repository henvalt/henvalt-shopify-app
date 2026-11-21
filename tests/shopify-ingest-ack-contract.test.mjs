import test from "node:test";
import assert from "node:assert/strict";
import { SHOPIFY_INGEST_ACK_CONTRACT as c } from "../cloudflare/shopify-ingest-ack-contract.mjs";

test("Shopify webhook uses explicit response mode and one shared acknowledgement node", () => {
  assert.equal(c.webhookResponseMode, "responseNode");
  assert.equal(c.respondNode, "Acknowledge Ingress Request");
  assert.equal(c.successEnvelopeNode, "Classify Result");
  assert.equal(c.rejectionEnvelopeNode, "Build Rejection Response");
  assert.equal(c.successResponseAfterNode, "Classify Result");
  assert.equal(c.successResponseBeforeNode, "Should Process?");
  assert.equal(c.continueExecutionAfterResponse, true);
});

test("all pre-ingest rejection paths must converge on an explicit response", () => {
  assert.deepEqual(c.preIngestFailureRoutes, [
    "HMAC Verified? false",
    "Is Valid false",
  ]);
  assert.deepEqual(c.preIngestFailureStatuses, {
    invalidHmac: 401,
    unknownTenant: 404,
    malformedEvent: 422,
    tenantLookupUnavailable: 503,
  });
});

test("accepted acknowledgement requires durable ingest and a complete RPC decision", () => {
  assert.deepEqual(c.acceptedIngestRequires, [
    "ingest_raw_webhook_v2 returned HTTP 2xx",
    "webhook_id is present",
    "should_process is an explicit boolean",
  ]);
  assert.deepEqual(c.acceptedStatuses, [200]);
  assert.deepEqual(c.duplicateStatuses, [200]);
  assert.deepEqual(c.retryableStatuses, [503]);
  assert.deepEqual(c.rejectStatuses, [401, 404, 422]);
  assert.equal(c.responseCodeExpression, "={{ $json.__http }}");
  assert.equal(c.responseBodyExpression, "={{ $json.__body }}");
});

test("acknowledgement contract and nested collections are immutable", () => {
  assert.equal(Object.isFrozen(c), true);
  for (const key of [
    "preIngestFailureRoutes",
    "acceptedIngestRequires",
    "preIngestFailureStatuses",
    "acceptedStatuses",
    "retryableStatuses",
    "rejectStatuses",
    "duplicateStatuses",
  ]) assert.equal(Object.isFrozen(c[key]), true, key);
});

import test from "node:test";
import assert from "node:assert/strict";
import {
  SHOPIFY_INGEST_ACK_CONTRACT as c,
  buildPreIngestRejection,
  classifyIngestResponse,
} from "../cloudflare/shopify-ingest-ack-contract.mjs";

const context = { eventId: "evt-123", correlationId: "corr-123" };

test("Shopify webhook uses explicit response mode and one shared acknowledgement node", () => {
  assert.equal(c.webhookResponseMode, "responseNode");
  assert.equal(c.respondNode, "Acknowledge Ingress Request");
  assert.equal(c.successEnvelopeNode, "Classify Result");
  assert.equal(c.rejectionEnvelopeNode, "Build Rejection Response");
  assert.equal(c.successResponseAfterNode, "Classify Result");
  assert.equal(c.successResponseBeforeNode, "Webhook execution ends after acknowledgement");
  assert.equal(c.continueExecutionAfterResponse, false);
});

test("all pre-ingest rejection paths have explicit fail-closed response codes", () => {
  assert.deepEqual(c.preIngestFailureRoutes, [
    "HMAC Verified? false",
    "Is Valid false",
  ]);
  assert.deepEqual(c.preIngestFailureStatuses, {
    invalidHmac: 401,
    hmacVerifierUnavailable: 503,
    unknownTenant: 404,
    malformedEvent: 422,
    tenantLookupUnavailable: 503,
  });
  assert.equal(buildPreIngestRejection("invalidHmac", context).http, 401);
  assert.equal(buildPreIngestRejection("hmacVerifierUnavailable", context).http, 503);
  assert.equal(buildPreIngestRejection("unknownTenant", context).http, 404);
  assert.equal(buildPreIngestRejection("malformedEvent", context).http, 422);
  assert.equal(buildPreIngestRejection("tenantLookupUnavailable", context).http, 503);
});

test("new durable ingest returns 200 only when a replay job is durably active", () => {
  const result = classifyIngestResponse({
    statusCode: 201,
    body: [{
      webhook_id: "wh-1",
      is_duplicate: false,
      should_process: true,
      processing_status: "PROCESSING",
      replay_job_id: "job-1",
      replay_job_status: "QUEUED",
    }],
  }, context);
  assert.equal(result.http, 200);
  assert.equal(result.asyncProcessingGuaranteed, true);
  assert.equal(Object.hasOwn(result, "asyncProcessingGuaranteed"), true);
  assert.equal(result.webhookId, "wh-1");
  assert.equal(result.body.status, "accepted");
  assert.equal(result.body.replay_job_id, "job-1");
});

test("processed and actively queued duplicates return 200 without duplicate processing", () => {
  const processed = classifyIngestResponse({
    statusCode: 200,
    body: [{
      webhook_id: "wh-2",
      is_duplicate: true,
      should_process: false,
      processing_status: "PROCESSED",
    }],
  }, context);
  const processing = classifyIngestResponse({
    statusCode: 200,
    body: [{
      webhook_id: "wh-3",
      is_duplicate: true,
      should_process: false,
      processing_status: "PROCESSING",
      replay_job_id: "job-3",
      replay_job_status: "RUNNING",
    }],
  }, context);
  assert.equal(processed.http, 200);
  assert.equal(processed.asyncProcessingGuaranteed, false);
  assert.equal(processed.body.status, "duplicate");
  assert.equal(processing.http, 200);
  assert.equal(processing.asyncProcessingGuaranteed, true);
  assert.equal(processing.body.status, "already_processing");
});

test("missing durable ID, decision or active replay job returns retryable 503", () => {
  for (const body of [
    [{ is_duplicate: false, should_process: true }],
    [{ webhook_id: "wh-4", is_duplicate: false }],
    [{ webhook_id: "wh-5", should_process: false, processing_status: "UNKNOWN" }],
    [{ webhook_id: "wh-6", is_duplicate: false, should_process: true, processing_status: "PROCESSING" }],
    [{
      webhook_id: "wh-7",
      is_duplicate: false,
      should_process: true,
      processing_status: "PROCESSING",
      replay_job_id: "job-7",
      replay_job_status: "DEAD_LETTER",
    }],
    [{
      webhook_id: "wh-8",
      is_duplicate: true,
      should_process: false,
      processing_status: "PROCESSING",
      replay_job_id: "job-8",
      replay_job_status: "DEAD_LETTER",
    }],
  ]) {
    const result = classifyIngestResponse({ statusCode: 200, body }, context);
    assert.equal(result.http, 503);
    assert.equal(result.asyncProcessingGuaranteed, false);
  }
});

test("generic 409 and transient backend failures are never acknowledged as duplicates", () => {
  for (const input of [
    { statusCode: 409, body: { message: "conflict" } },
    { statusCode: 503, body: { message: "unavailable" } },
    { error: "timeout" },
    {},
  ]) {
    const result = classifyIngestResponse(input, context);
    assert.equal(result.http, 503);
    assert.equal(result.asyncProcessingGuaranteed, false);
  }
});

test("authentication, tenant and validation errors map to explicit rejection codes", () => {
  assert.equal(classifyIngestResponse({ statusCode: 401 }, context).http, 401);
  assert.equal(classifyIngestResponse({ statusCode: 403 }, context).http, 401);
  assert.equal(classifyIngestResponse({ statusCode: 404 }, context).http, 404);
  assert.equal(classifyIngestResponse({ statusCode: 422 }, context).http, 422);
});

test("acknowledgement contract and nested collections are immutable", () => {
  assert.equal(Object.isFrozen(c), true);
  for (const key of [
    "preIngestFailureRoutes",
    "acceptedIngestRequires",
    "replayQueue",
    "conflictHandling",
    "preIngestFailureStatuses",
    "acceptedStatuses",
    "retryableStatuses",
    "rejectStatuses",
    "duplicateStatuses",
  ]) assert.equal(Object.isFrozen(c[key]), true, key);
});

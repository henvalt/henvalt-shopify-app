import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const snapshot = JSON.parse(readFileSync(
  new URL("./fixtures/n8n-shopify-ingest-route-snapshot.json", import.meta.url),
  "utf8",
));

test("active Shopify ingest webhook preserves raw request bytes for HMAC verification", () => {
  assert.equal(snapshot.webhook.method, "POST");
  assert.equal(snapshot.webhook.path, "henvalt/ingest");
  assert.equal(snapshot.webhook.rawBody, true);
});

test("Shopify HMAC verification and tenant resolution precede canonical ingestion", () => {
  const expected = [
    ["Event Webhook", "Validate & Normalize"],
    ["Validate & Normalize", "Engine Config"],
    ["Engine Config", "Verify Shopify HMAC"],
    ["Verify Shopify HMAC", "HMAC Verified?"],
    ["HMAC Verified?", "Resolve Shopify Tenant"],
    ["Resolve Shopify Tenant", "Bind Tenant Context"],
    ["Bind Tenant Context", "Is Valid"],
    ["Is Valid", "Supabase Ingest RPC"],
    ["Supabase Ingest RPC", "Classify Result"],
  ];
  assert.deepEqual(snapshot.orderedEdges, expected);
  assert.equal(snapshot.rpcs.hmac, "verify_shopify_webhook_hmac");
  assert.equal(snapshot.rpcs.tenant, "resolve_shopify_tenant");
  assert.equal(snapshot.rpcs.ingest, "ingest_raw_webhook_v2");
});

test("ingest result must explicitly authorize processing; duplicate and legacy responses fail closed", () => {
  assert.equal(snapshot.resultContract.processDecisionField, "should_process");
  assert.equal(snapshot.resultContract.duplicateStatus, "PROCESSED");
  assert.equal(snapshot.resultContract.missingDecisionFailsClosed, true);
});

test("active ingest snapshot explicitly flags early acknowledgement as a launch blocker", () => {
  assert.equal(snapshot.acknowledgement.webhookResponseMode, "onReceived");
  assert.equal(snapshot.acknowledgement.respondToWebhookNodeCount, 0);
  assert.equal(snapshot.acknowledgement.durableIngestRpc, "ingest_raw_webhook_v2");
  assert.equal(snapshot.acknowledgement.durableIngestOccursAfterHttpAcknowledgement, true);
  assert.equal(snapshot.acknowledgement.launchBlocker, true);
});

test("active classifier's generic 409 duplicate shortcut is a launch blocker until row identity is proven", () => {
  assert.equal(snapshot.resultContract.generic409WithoutWebhookIdCurrentlyAcknowledged, true);
  assert.equal(snapshot.resultContract.candidateMustRequireWebhookIdForEvery200, true);
  assert.equal(snapshot.resultContract.generic409MustBeRetryableWithoutDurableRow, true);
});

test("live normalizer must use Shopify delivery ID, not event correlation ID, for deduplication", () => {
  assert.deepEqual(snapshot.shopifyIdentity.currentSourceEventIdPrecedence, [
    "body.event_id",
    "x-shopify-event-id",
    "x-shopify-webhook-id",
    "body.id",
  ]);
  assert.equal(snapshot.shopifyIdentity.requiredDeliveryIdHeader, "x-shopify-webhook-id");
  assert.equal(snapshot.shopifyIdentity.eventCorrelationHeader, "x-shopify-event-id");
  assert.equal(snapshot.shopifyIdentity.correctSourceEventId, "x-shopify-webhook-id");
  assert.equal(snapshot.shopifyIdentity.eventCorrelationIsNotDeduplicationKey, true);
  assert.equal(snapshot.shopifyIdentity.launchBlocker, true);
});

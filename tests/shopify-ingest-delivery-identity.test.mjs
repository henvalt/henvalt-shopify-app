import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const source = readFileSync(new URL("../n8n/shopify-ingest-normalizer-candidate.js", import.meta.url), "utf8");
const normalize = new Function("$json", "$input", "$execution", source);

function run(headers = {}, body = {}) {
  return normalize(
    { headers, body, query: {} },
    { item: { binary: {} } },
    { id: "synthetic-execution" },
  );
}

test("Shopify event uses the unique delivery ID even when body/event IDs differ", () => {
  const result = run({
    "x-shopify-shop-domain": "synthetic.myshopify.com",
    "x-shopify-topic": "orders/paid",
    "x-shopify-webhook-id": "delivery-A",
    "x-shopify-event-id": "shared-event",
  }, { id: "order-123", event_id: "body-event-456" });

  assert.equal(result.__valid, true);
  assert.equal(result.event.event_id, "delivery-A");
  assert.equal(result.ingest.source_event_id, "delivery-A");
  assert.equal(result.ingest.idempotency_key, "shopify:synthetic.myshopify.com:delivery-A");
  assert.equal(result.ingest.metadata.shopify_event_id, "shared-event");
  assert.equal(result.ingest.metadata.shopify_webhook_id, "delivery-A");
});

test("Shopify topic header overrides conflicting event_type and type fields in the signed payload", () => {
  const result = run({
    "x-shopify-shop-domain": "synthetic.myshopify.com",
    "x-shopify-topic": "orders/paid",
    "x-shopify-webhook-id": "delivery-topic-001",
  }, {
    id: "order-123",
    event_type: "internal/fake",
    type: "orders/cancelled",
  });

  assert.equal(result.__valid, true);
  assert.equal(result.event.event_type, "orders/paid");
  assert.equal(result.ingest.topic, "orders/paid");
  assert.equal(result.ingest.metadata.shopify_topic, "orders/paid");
});

test("separate Shopify deliveries sharing an event correlation ID remain distinct", () => {
  const headers = {
    "x-shopify-shop-domain": "synthetic.myshopify.com",
    "x-shopify-topic": "orders/paid",
    "x-shopify-event-id": "same-correlation-id",
  };
  const first = run({ ...headers, "x-shopify-webhook-id": "delivery-A" }, { id: "order-123" });
  const second = run({ ...headers, "x-shopify-webhook-id": "delivery-B" }, { id: "order-123" });

  assert.notEqual(first.ingest.source_event_id, second.ingest.source_event_id);
  assert.notEqual(first.ingest.idempotency_key, second.ingest.idempotency_key);
  assert.equal(first.ingest.metadata.shopify_event_id, second.ingest.metadata.shopify_event_id);
});

test("missing Shopify delivery ID is invalid and never falls back to event ID or body ID", () => {
  const result = run({
    "x-shopify-shop-domain": "synthetic.myshopify.com",
    "x-shopify-topic": "orders/paid",
    "x-shopify-event-id": "correlation-only",
  }, { id: "order-123", event_id: "body-event-456" });

  assert.equal(result.__valid, false);
  assert.equal(result.ingest.source_event_id, null);
  assert.ok(result.__missing.includes("x-shopify-webhook-id"));
});

test("internal events retain their existing event ID and idempotency behavior", () => {
  const result = run({}, {
    source: "internal",
    tenant_reference: "tenant-reference",
    tenant_id: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
    event_id: "internal-event-1",
    event_type: "internal/test",
  });

  assert.equal(result.__valid, true);
  assert.equal(result.ingest.source_event_id, "internal-event-1");
  assert.equal(result.ingest.idempotency_key, "internal:tenant-reference:internal/test:internal-event-1");
});

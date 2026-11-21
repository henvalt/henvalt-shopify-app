import test from "node:test";
import assert from "node:assert/strict";
import { buildVerifiedWebhookHeaders } from "../cloudflare/webhook-forwarding.mjs";

test("forwards only the Shopify webhook metadata required by the existing ingest contract", () => {
  const request = new Request("https://worker.example/shopify/webhooks", {
    method: "POST",
    headers: {
      "content-type": "application/json",
      "x-shopify-shop-domain": "merchant.myshopify.com",
      "x-shopify-topic": "orders/create",
      "x-shopify-hmac-sha256": "verified-signature",
      "x-shopify-webhook-id": "webhook-123",
      "x-shopify-event-id": "event-123",
    },
  });
  const headers = buildVerifiedWebhookHeaders(request);
  assert.equal(headers.get("content-type"), "application/json");
  assert.equal(headers.get("x-shopify-shop-domain"), "merchant.myshopify.com");
  assert.equal(headers.get("x-shopify-topic"), "orders/create");
  assert.equal(headers.get("x-shopify-hmac-sha256"), "verified-signature");
  assert.equal(headers.get("x-shopify-webhook-id"), "webhook-123");
  assert.equal(headers.get("x-shopify-event-id"), "event-123");
  assert.deepEqual([...headers.keys()].sort(), [
    "content-type",
    "x-shopify-event-id",
    "x-shopify-hmac-sha256",
    "x-shopify-shop-domain",
    "x-shopify-topic",
    "x-shopify-webhook-id",
  ]);
});

test("does not forward caller-supplied credentials or forged internal identity headers", () => {
  const request = new Request("https://worker.example/shopify/webhooks", {
    method: "POST",
    headers: {
      "x-shopify-shop-domain": "merchant.myshopify.com",
      "x-shopify-topic": "orders/create",
      "x-shopify-hmac-sha256": "verified-signature",
      "authorization": "Bearer attacker-token",
      "cookie": "session=attacker",
      "x-henvalt-tenant-id": "attacker-tenant",
      "x-henvalt-connection-id": "attacker-connection",
      "x-henvalt-app-key": "public_v1",
      "x-forwarded-for": "127.0.0.1",
    },
  });
  const headers = buildVerifiedWebhookHeaders(request);
  for (const name of [
    "authorization",
    "cookie",
    "x-henvalt-tenant-id",
    "x-henvalt-connection-id",
    "x-henvalt-app-key",
    "x-forwarded-for",
  ]) assert.equal(headers.has(name), false, name);
});

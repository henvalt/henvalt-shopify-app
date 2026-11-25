import test from "node:test";
import assert from "node:assert/strict";
import { SHOPIFY_WEBHOOK_SPECS, verifyWebhookDestination } from "../supabase/functions/henvalt-shopify-oauth/webhook-specs.mjs";

test("OAuth registers the complete V1 Shopify webhook contract exactly once", () => {
  const topics = SHOPIFY_WEBHOOK_SPECS.map(({ topic }) => topic);
  const gqlTopics = SHOPIFY_WEBHOOK_SPECS.map(({ gql }) => gql);
  assert.equal(SHOPIFY_WEBHOOK_SPECS.length, 12);
  assert.equal(new Set(topics).size, topics.length);
  assert.equal(new Set(gqlTopics).size, gqlTopics.length);
  for (const topic of [
    "orders/create", "orders/updated", "orders/paid", "orders/cancelled",
    "refunds/create", "order_transactions/create", "checkouts/create",
    "checkouts/update", "carts/create", "carts/update",
    "customers_email_marketing_consent/update", "app/uninstalled",
  ]) assert.ok(topics.includes(topic), `missing webhook topic: ${topic}`);
});

test("Webhook registration contract is immutable", () => {
  assert.equal(Object.isFrozen(SHOPIFY_WEBHOOK_SPECS), true);
});

test("webhook verification requires exactly one subscription at the intended ingress", () => {
  assert.deepEqual(verifyWebhookDestination(
    [{ id: "gid://shopify/WebhookSubscription/1", topic: "ORDERS_CREATE", uri: "https://staging-ingress.invalid/shopify/webhooks" }],
    "ORDERS_CREATE",
    "https://staging-ingress.invalid/shopify/webhooks",
  ), { verified: true, id: "gid://shopify/WebhookSubscription/1" });
  assert.deepEqual(verifyWebhookDestination([], "ORDERS_CREATE", "https://staging-ingress.invalid/shopify/webhooks"),
    { verified: false, reason: "WEBHOOK_SUBSCRIPTION_MISSING" });
});

test("webhook verification rejects stale destinations and duplicate topic subscriptions", () => {
  assert.deepEqual(verifyWebhookDestination(
    [{ id: "old", topic: "ORDERS_CREATE", uri: "https://production-ingress.invalid/shopify/webhooks" }],
    "ORDERS_CREATE",
    "https://staging-ingress.invalid/shopify/webhooks",
  ), { verified: false, reason: "WEBHOOK_DESTINATION_MISMATCH" });
  assert.deepEqual(verifyWebhookDestination([
    { id: "old", topic: "ORDERS_CREATE", uri: "https://production-ingress.invalid/shopify/webhooks" },
    { id: "new", topic: "ORDERS_CREATE", uri: "https://staging-ingress.invalid/shopify/webhooks" },
  ], "ORDERS_CREATE", "https://staging-ingress.invalid/shopify/webhooks"),
  { verified: false, reason: "DUPLICATE_WEBHOOK_SUBSCRIPTIONS" });
});

import test from "node:test";
import assert from "node:assert/strict";
import { SHOPIFY_WEBHOOK_SPECS } from "../supabase/functions/henvalt-shopify-oauth/webhook-specs.mjs";

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

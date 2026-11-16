import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const migration = readFileSync(new URL("../supabase/migrations/202611160011_shopify_order_conversion_projection_v2.sql", import.meta.url), "utf8");
const edge = readFileSync(new URL("../supabase/functions/henvalt-shopify-webhook-ingress/index.ts", import.meta.url), "utf8");
const docs = readFileSync(new URL("../docs/shopify-order-conversion-projection-v2.md", import.meta.url), "utf8");

test("order identity is scoped to exact Shopify connection", () => {
  assert.match(migration, /UNIQUE \(shopify_connection_id, shopify_order_id\)/);
  assert.match(migration, /FOREIGN KEY \(shopify_connection_id, tenant_id\)/);
  assert.match(migration, /shopify_order_identity_v2_verified_source_fkey/);
});

test("order-to-checkout conversion uses checkout_token and exact connection", () => {
  assert.match(migration, /v_payload->>'checkout_token'/);
  assert.match(migration, /shopify_checkout_token = v_checkout_token/);
  assert.match(migration, /shopify_connection_id = v_route\.connection_id/);
  assert.match(migration, /checkout_status = 'COMPLETED'/);
  assert.match(docs, /uses `checkout_token`, not the removed `checkout_id`/);
});

test("order projection verifies exact receipt digest and server-derived install", () => {
  assert.match(migration, /project_verified_shopify_order_v2/);
  assert.match(migration, /raw_body_sha256/);
  assert.match(migration, /RECEIPT_BODY_MISMATCH/);
  assert.match(migration, /route_tokens/);
  assert.match(migration, /REVOKE ALL ON FUNCTION henvalt\.project_verified_shopify_order_v2/);
  assert.match(migration, /GRANT EXECUTE ON FUNCTION henvalt\.project_verified_shopify_order_v2\(text,text,text\)\s+TO service_role/);
});

test("order webhook ingress projects before acknowledging", () => {
  assert.match(edge, /topic==="orders\/create"/);
  assert.match(edge, /project_verified_shopify_order_v2/);
  assert.match(edge, /order_projection_unavailable/);
});

test("order projection stores no direct customer contact data or raw payload", () => {
  assert.doesNotMatch(migration, /email|phone|address|line_items/i);
  assert.match(docs, /No email, phone, address, line items or raw body are stored/);
});

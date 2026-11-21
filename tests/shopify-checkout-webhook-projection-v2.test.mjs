import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const migration = readFileSync(new URL("../supabase/migrations/202611160010_shopify_checkout_webhook_projection_v2.sql", import.meta.url), "utf8");
const edge = readFileSync(new URL("../supabase/functions/henvalt-shopify-webhook-ingress/index.ts", import.meta.url), "utf8");
const docs = readFileSync(new URL("../docs/shopify-checkout-webhook-projection-v2.md", import.meta.url), "utf8");

test("checkout identity uses Shopify token, not removed checkout id", () => {
  assert.match(migration, /ALTER COLUMN shopify_checkout_id DROP NOT NULL/);
  assert.match(migration, /ADD COLUMN IF NOT EXISTS shopify_checkout_token text/);
  assert.match(migration, /UNIQUE INDEX shopify_checkout_identity_v2_connection_token_uidx/);
  assert.match(migration, /v_payload->>'token'/);
  assert.match(docs, /removed `id` from `checkouts\/create` and `checkouts\/update`/);
});

test("checkout projection is bound to an HMAC-verified exact-store receipt", () => {
  assert.match(migration, /shopify_webhook_route_tokens/);
  assert.match(migration, /shopify_webhook_deliveries/);
  assert.match(migration, /raw_body_sha256/);
  assert.match(migration, /RECEIPT_BODY_MISMATCH/);
  assert.match(migration, /p_delivery_id/);
  assert.match(migration, /REVOKE ALL ON FUNCTION henvalt\.project_verified_shopify_checkout_v2/);
  assert.match(migration, /GRANT EXECUTE ON FUNCTION henvalt\.project_verified_shopify_checkout_v2\(text,text,text\)\s+TO service_role/);
});

test("edge ingress retries checkout projection after verified receipt acceptance", () => {
  assert.match(edge, /accept_shopify_webhook_v2/);
  assert.match(edge, /topic==="checkouts\/create" \|\| topic==="checkouts\/update"/);
  assert.match(edge, /project_verified_shopify_checkout_v2/);
  assert.match(edge, /p_raw_body_base64:encodedBody/);
  assert.match(edge, /checkout_projection_unavailable/);
});

test("checkout projection does not persist contact or raw customer data", () => {
  assert.doesNotMatch(migration, /email|phone|address|line_items/i);
  assert.match(docs, /does not store email, phone, address, line items or raw payload/);
  assert.match(docs, /not yet a complete abandoned-checkout recovery pipeline/);
});

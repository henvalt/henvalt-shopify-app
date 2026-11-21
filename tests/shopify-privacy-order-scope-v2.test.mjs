import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const migration = readFileSync(new URL("../supabase/migrations/202611170021_shopify_privacy_order_scope_v2.sql", import.meta.url), "utf8");

test("privacy order scope is minimal, exact-receipt-bound and inaccessible to clients", () => {
  assert.match(migration, /PRIMARY KEY \(receipt_id, scope_kind, ordinal\)/);
  assert.match(migration, /FOREIGN KEY \(receipt_id\)[\s\S]*shopify_privacy_webhook_deliveries\(id\)/);
  assert.match(migration, /REVOKE ALL ON henvalt\.shopify_privacy_webhook_order_scope_v2[\s\S]*FROM PUBLIC, anon, authenticated, service_role/);
  assert.match(migration, /GRANT SELECT, INSERT ON henvalt\.shopify_privacy_webhook_order_scope_v2 TO service_role/);
  const tableDdl = migration.slice(migration.indexOf("CREATE TABLE IF NOT EXISTS henvalt.shopify_privacy_webhook_order_scope_v2"), migration.indexOf("CREATE INDEX IF NOT EXISTS shopify_privacy_webhook_order_scope_v2_lookup_idx"));
  assert.doesNotMatch(tableDdl, /email|phone|raw_body|payload/i);
});

test("verified privacy ingress validates and persists only Shopify's topic-specific order IDs", () => {
  assert.match(migration, /orders_requested/);
  assert.match(migration, /orders_to_redact/);
  assert.match(migration, /'REQUESTED'/);
  assert.match(migration, /'TO_REDACT'/);
  assert.match(migration, /INVALID_ORDER_SCOPE/);
  assert.match(migration, /jsonb_array_length\(v_order_array\) > 10000/);
  assert.match(migration, /count\(DISTINCT value #>> '\{\}'\)/);
  assert.match(migration, /IF v_inserted IS NOT NULL AND v_order_scope IS NOT NULL/);
});

test("order IDs are positive integer strings bounded to signed bigint and duplicate receipts remain idempotent", () => {
  assert.match(migration, /\^\[1-9\]\[0-9\]\{0,19\}\$/);
  assert.match(migration, /9223372036854775807/);
  assert.match(migration, /DELIVERY_ID_BODY_MISMATCH/);
  assert.match(migration, /ON CONFLICT \(app_key, shop_domain, webhook_id\) DO NOTHING/);
});

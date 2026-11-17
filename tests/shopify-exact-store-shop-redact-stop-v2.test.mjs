import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const migration = readFileSync(
  "supabase/migrations/202611170019_shopify_exact_store_shop_redact_stop_v2.sql",
  "utf8"
);
const integration = readFileSync(
  "tests/sql/shopify-exact-store-shop-redact-stop-v2.test.sql",
  "utf8"
);

test("verified shop/redact stops only the receipt's immutable connection", () => {
  assert.match(migration, /NEW\.topic <> 'shop\/redact'/);
  assert.match(migration, /sc\.id = NEW\.connection_id[\s\S]*sc\.tenant_id = NEW\.tenant_id[\s\S]*sc\.app_key = NEW\.app_key[\s\S]*sc\.shop_domain = NEW\.shop_domain/);
  assert.match(migration, /SET active = false[\s\S]*WHERE id = NEW\.connection_id[\s\S]*AND tenant_id = NEW\.tenant_id/);
  assert.match(migration, /shopify_webhook_route_tokens[\s\S]*connection_id = NEW\.connection_id/);
  assert.match(migration, /pixel_keys[\s\S]*shopify_connection_id = NEW\.connection_id/);
});

test("shop/redact stop closes only untouched recovery work and removes transient permits", () => {
  assert.match(migration, /state = 'STORE_INACTIVE'/);
  assert.match(migration, /status = 'CLOSED'/);
  assert.match(migration, /status = 'READY_FOR_AUTHORIZATION'[\s\S]*NOT EXISTS \([\s\S]*shopify_recovery_send_attempt_v2/);
  assert.match(migration, /DELETE FROM henvalt\.shopify_delivery_permits_v2[\s\S]*shopify_connection_id = NEW\.connection_id/);
  assert.doesNotMatch(migration, /DELETE FROM henvalt\.shopify_(customer_identity|checkout_identity|order_identity|recovery_send_attempt|delivery_cost_reservations)/i);
});

test("shop/redact remains queued for review and never claims deletion completed", () => {
  assert.match(migration, /SET processing_status = 'PROCESSING'/);
  assert.match(migration, /AND processing_status = 'REVIEW_REQUIRED'/);
  assert.match(integration, /shop-redact-stop-store-a-2026-11-17/);
  assert.match(integration, /shop redact stop leaked into another store/i);
  assert.match(integration, /v_processed_at IS NOT NULL/);
  assert.match(integration, /ROLLBACK/);
});

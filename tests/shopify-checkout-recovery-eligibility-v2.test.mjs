import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const migration = readFileSync(new URL("../supabase/migrations/202611170001_shopify_checkout_recovery_eligibility_v2.sql", import.meta.url), "utf8");
const docs = readFileSync(new URL("../docs/shopify-checkout-recovery-eligibility-v2.md", import.meta.url), "utf8");

test("eligibility rows preserve exact-store checkout, tenant and receipt lineage", () => {
  assert.match(migration, /FOREIGN KEY \(checkout_identity_id, tenant_id, shopify_connection_id\)/);
  assert.match(migration, /FOREIGN KEY \(source_delivery_id, tenant_id, shopify_connection_id\)/);
  assert.match(migration, /UNIQUE \(shopify_connection_id, checkout_token\)/);
});

test("candidate selection requires inactivity and exact-store active app, store and tenant", () => {
  assert.match(migration, /ch\.updated_at <= pg_catalog\.now\(\) - p_minimum_inactive_for/);
  assert.match(migration, /ar\.app_key = sc\.app_key/);
  assert.match(migration, /ar\.lifecycle_status = 'active'/);
  assert.match(migration, /sc\.active IS TRUE/);
  assert.match(migration, /t\.status = 'ACTIVE'/);
});

test("orders suppress only the matching store checkout token", () => {
  assert.match(migration, /o\.shopify_connection_id = ch\.shopify_connection_id/);
  assert.match(migration, /o\.checkout_token = ch\.shopify_checkout_token/);
});

test("candidate refresh is bounded, service-only and never authorizes delivery", () => {
  assert.match(migration, /p_minimum_inactive_for < interval '15 minutes'/);
  assert.match(migration, /p_minimum_inactive_for > interval '7 days'/);
  assert.match(migration, /p_limit > 500/);
  assert.match(migration, /REVOKE ALL ON FUNCTION henvalt\.refresh_shopify_checkout_recovery_candidates_v2/);
  assert.match(migration, /GRANT EXECUTE ON FUNCTION henvalt\.refresh_shopify_checkout_recovery_candidates_v2\(interval,integer\)\s+TO service_role/);
  assert.match(migration, /delivery_authorized', false/);
});

test("candidate table stores no shopper contact data", () => {
  assert.doesNotMatch(migration, /\bemail\s+text|\bphone\s+text|\baddress\s+text|\braw_payload\b/i);
  assert.match(docs, /contains no email, phone, address, or raw webhook payload/i);
});

import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const migration = readFileSync(new URL("../supabase/migrations/202611170002_shopify_recovery_opportunity_foundation_v2.sql", import.meta.url), "utf8");

test("opportunity lineage is tied to the same app, store, tenant, checkout, customer and receipt", () => {
  assert.match(migration, /FOREIGN KEY \(shopify_connection_id, tenant_id, app_key\)/);
  assert.match(migration, /FOREIGN KEY \(candidate_id, tenant_id, shopify_connection_id\)/);
  assert.match(migration, /FOREIGN KEY \(checkout_identity_id, tenant_id, shopify_connection_id\)/);
  assert.match(migration, /FOREIGN KEY \(customer_identity_id, tenant_id, shopify_connection_id\)/);
  assert.match(migration, /FOREIGN KEY \(source_delivery_id, tenant_id, shopify_connection_id\)/);
});

test("promotion requires an eligible open checkout and active exact app, store and tenant", () => {
  assert.match(migration, /c\.state = 'READY_FOR_CONTACT_RESOLUTION'/);
  assert.match(migration, /c\.eligible_after <= pg_catalog\.now\(\)/);
  assert.match(migration, /ch\.checkout_status = 'OPEN'/);
  assert.match(migration, /sc\.active IS TRUE/);
  assert.match(migration, /ar\.lifecycle_status = 'active'/);
  assert.match(migration, /t\.status = 'ACTIVE'/);
});

test("same-store order suppresses opportunity creation", () => {
  assert.match(migration, /o\.shopify_connection_id = c\.shopify_connection_id/);
  assert.match(migration, /o\.checkout_token = c\.checkout_token/);
});

test("missing customer identity or amount/currency is quarantined for review", () => {
  assert.match(migration, /WHEN ch\.customer_identity_id IS NOT NULL/);
  assert.match(migration, /AND ch\.total_value IS NOT NULL/);
  assert.match(migration, /AND ch\.currency ~ '\^\[A-Z\]\{3\}\$'/);
  assert.match(migration, /ELSE 'REVIEW_REQUIRED'/);
});

test("a later order or inactive checkout closes only its same-store opportunity", () => {
  assert.match(migration, /o\.shopify_connection_id = c\.shopify_connection_id/);
  assert.match(migration, /o\.checkout_token = c\.checkout_token/);
  assert.match(migration, /SET status = 'CONVERTED'/);
  assert.match(migration, /SET status = 'CLOSED'/);
});

test("promotion is bounded, idempotent, service-only and cannot authorize delivery", () => {
  assert.match(migration, /p_limit < 1 OR p_limit > 500/);
  assert.match(migration, /UNIQUE \(candidate_id\)/);
  assert.match(migration, /ON CONFLICT \(candidate_id\) DO NOTHING/);
  assert.match(migration, /FOR UPDATE OF c SKIP LOCKED/);
  assert.match(migration, /GRANT EXECUTE ON FUNCTION henvalt\.promote_shopify_checkout_recovery_candidates_v2\(integer\)\s+TO service_role/);
  assert.match(migration, /delivery_authorized', false/);
});

test("opportunity table contains no shopper contact data and is not connected to legacy delivery", () => {
  assert.doesNotMatch(migration, /\bemail\s+text|\bphone\s+text|\baddress\s+text|\braw_payload\b/i);
  assert.match(migration, /REVOKE ALL ON henvalt\.shopify_recovery_opportunity_v2[\s\S]*FROM PUBLIC, anon, authenticated, service_role/);
});

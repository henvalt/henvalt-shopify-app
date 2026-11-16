import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const migration = readFileSync(
  new URL("../supabase/migrations/202611160001_shopify_webhook_identity_foundation.sql", import.meta.url),
  "utf8",
);
const preflight = readFileSync(
  new URL("../docs/sql/shopify-webhook-identity-foundation-preflight-read-only.sql", import.meta.url),
  "utf8",
);

test("identity foundation is additive and preserves legacy webhook constraints", () => {
  assert.match(migration, /CREATE TABLE IF NOT EXISTS henvalt\.shopify_app_registry/);
  assert.match(migration, /ADD COLUMN IF NOT EXISTS app_key text/);
  assert.match(migration, /CREATE TABLE IF NOT EXISTS henvalt\.shopify_webhook_route_tokens/);
  assert.match(migration, /CREATE TABLE IF NOT EXISTS henvalt\.shopify_webhook_deliveries/);
  assert.match(migration, /UNIQUE \(connection_id, shopify_delivery_id\)/);
  assert.doesNotMatch(migration, /DROP\s+(TABLE|COLUMN|INDEX|CONSTRAINT)|TRUNCATE\s|DELETE\s+FROM|UPDATE\s+henvalt\.(shopify_connections|webhook_events)/i);
  assert.doesNotMatch(migration, /ALTER TABLE henvalt\.webhook_events/i);
});

test("route and inbox records enforce exact connection, tenant and app lineage", () => {
  assert.equal((migration.match(/FOREIGN KEY \(connection_id, tenant_id, app_key\)/g) || []).length, 2);
  assert.match(migration, /REFERENCES henvalt\.shopify_connections \(id, tenant_id, app_key\)/);
  assert.match(migration, /token_hash ~ '\^\[0-9a-f\]\{64\}\$'/);
  assert.match(migration, /raw_body_sha256 ~ '\^\[0-9a-f\]\{64\}\$'/);
  assert.match(migration, /shopify_app_registry_secret_ref_nonempty/);
  assert.match(migration, /webhook_secret_ref is a Vault reference, never a decrypted secret/i);
});

test("identity tables are not exposed to browser roles", () => {
  for (const table of ["shopify_app_registry", "shopify_webhook_route_tokens", "shopify_webhook_deliveries"]) {
    assert.match(migration, new RegExp(`ALTER TABLE henvalt\\.${table} ENABLE ROW LEVEL SECURITY`));
    assert.match(migration, new RegExp(`REVOKE ALL ON henvalt\\.${table} FROM PUBLIC, anon, authenticated`));
    assert.match(migration, new RegExp(`GRANT SELECT, INSERT, UPDATE ON henvalt\\.${table} TO service_role`));
  }
});

test("preflight is read-only and flags unresolved legacy and domain ambiguity", () => {
  assert.match(preflight, /lower\(btrim\(shop_domain\)\)/);
  assert.match(preflight, /app_key IS NULL/);
  assert.match(preflight, /legacy_rows_that_will_remain_unattributed/);
  assert.doesNotMatch(preflight, /\b(INSERT|UPDATE|DELETE|ALTER|DROP|TRUNCATE)\b/i);
});

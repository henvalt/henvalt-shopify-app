import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const sql = readFileSync(
  new URL("../supabase/migrations/202611160002_shopify_webhook_verified_inbox_rpc.sql", import.meta.url),
  "utf8",
);

test("V2 webhook RPC derives connection and app from hashed route token", () => {
  assert.match(sql, /CREATE OR REPLACE FUNCTION henvalt\.accept_shopify_webhook_v2/);
  assert.match(sql, /extensions\.digest\(convert_to\(p_route_token, 'UTF8'\), 'sha256'\)/);
  assert.match(sql, /JOIN henvalt\.shopify_connections sc/);
  assert.match(sql, /JOIN henvalt\.shopify_app_registry ar/);
  assert.doesNotMatch(sql, /p_(tenant_id|connection_id|app_key)\b/i);
});

test("V2 verifies app-specific Vault HMAC over the raw body", () => {
  assert.match(sql, /vault\.decrypted_secrets/);
  assert.match(sql, /ds\.name = v_route\.webhook_secret_ref/);
  assert.match(sql, /extensions\.hmac\(v_body, convert_to\(v_secret, 'UTF8'\), 'sha256'\)/);
  assert.match(sql, /HMAC_INVALID/);
  assert.doesNotMatch(sql, /RETURN\s+v_secret|SELECT\s+v_secret/i);
});

test("V2 rejects cross-store routing and validates body shop identity when available", () => {
  assert.match(sql, /lower\(p_shop_domain\) <> v_route\.shop_domain/);
  assert.match(sql, /SHOP_DOMAIN_MISMATCH/);
  assert.match(sql, /v_payload->>'shop_id'/);
  assert.match(sql, /SHOP_ID_MISMATCH/);
  assert.match(sql, /APP_OR_CONNECTION_INACTIVE/);
});

test("V2 persists verified delivery idempotently before acknowledging", () => {
  assert.match(sql, /INSERT INTO henvalt\.shopify_webhook_deliveries/);
  assert.match(sql, /ON CONFLICT \(connection_id, shopify_delivery_id\) DO NOTHING/);
  assert.match(sql, /hmac_verified_at/);
  assert.match(sql, /receipt_status := 'RECEIVED'/);
  assert.match(sql, /receipt_status := 'DUPLICATE'/);
});

test("V2 RPC is restricted to service_role and never exposes secret material", () => {
  assert.match(sql, /SECURITY DEFINER/);
  assert.match(sql, /SET search_path TO 'pg_catalog', 'henvalt', 'vault', 'extensions', 'pg_temp'/);
  assert.match(sql, /REVOKE ALL ON FUNCTION henvalt\.accept_shopify_webhook_v2[^;]+FROM PUBLIC, anon, authenticated/);
  assert.match(sql, /GRANT EXECUTE ON FUNCTION henvalt\.accept_shopify_webhook_v2[^;]+TO service_role/);
  assert.doesNotMatch(sql, /RETURNS TABLE\s*\([^)]*secret/i);
});

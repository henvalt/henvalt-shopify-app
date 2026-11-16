import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const sql = readFileSync(new URL("../supabase/migrations/202611160004_shopify_oauth_app_aware_finalizer.sql", import.meta.url), "utf8");

test("app-aware finalizer binds client, app, OAuth state and exact connection atomically", () => {
  assert.match(sql, /v_state\.app_key IS DISTINCT FROM p_app_key/i);
  assert.match(sql, /shopify_client_id = p_shopify_client_id/i);
  assert.match(sql, /lifecycle_status = 'active'/i);
  assert.match(sql, /pg_advisory_xact_lock\(hashtextextended\(p_shop_domain, 0\)\)/i);
  assert.match(sql, /app_key IS NULL OR app_key = p_app_key/i);
  assert.match(sql, /shopify_connection_bound_to_different_app/i);
  assert.match(sql, /control_plane_finalize_shopify_oauth_install_expiring_for_owner/i);
});

test("route token is validated, hashed, and stored only after app binding", () => {
  assert.match(sql, /p_route_token !~ '\^\[0-9a-f\]\{64\}\$'/i);
  assert.match(sql, /extensions\.digest\(convert_to\(p_route_token, 'UTF8'\),\s*'sha256'\)/i);
  assert.match(sql, /INSERT INTO henvalt\.shopify_webhook_route_tokens/i);
  assert.doesNotMatch(sql, /INSERT INTO henvalt\.shopify_webhook_route_tokens\s*\([^)]*token\s*,/is);
  assert.match(sql, /REVOKE ALL ON FUNCTION[\s\S]*FROM PUBLIC, anon, authenticated/i);
  assert.match(sql, /TO service_role/i);
});

test("migration is additive and does not seed or rewrite legacy identities", () => {
  assert.doesNotMatch(sql, /DROP\s+(TABLE|COLUMN|INDEX|CONSTRAINT)|TRUNCATE\s|DELETE\s+FROM|UPDATE\s+henvalt\.shopify_connections[\s\S]*WHERE\s+app_key\s+IS\s+NULL/i);
  assert.doesNotMatch(sql, /INSERT INTO henvalt\.shopify_app_registry/i);
});

import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const sql = readFileSync(new URL("../supabase/migrations/202611160005_shopify_app_oauth_secret_resolver.sql", import.meta.url), "utf8");

test("OAuth app identity is derived from configured client ID and active registry row", () => {
  assert.match(sql, /WHERE shopify_client_id = p_shopify_client_id/i);
  assert.match(sql, /lifecycle_status = 'active'/i);
  assert.match(sql, /v_app\.webhook_secret_ref/i);
  assert.match(sql, /FROM vault\.decrypted_secrets/i);
});

test("decrypted app secret is restricted to service-role server execution", () => {
  assert.match(sql, /REVOKE ALL ON FUNCTION[\s\S]*FROM PUBLIC, anon, authenticated/i);
  assert.match(sql, /GRANT EXECUTE ON FUNCTION[\s\S]*TO service_role/i);
  assert.doesNotMatch(sql, /RAISE NOTICE|RAISE LOG|RAISE WARNING/i);
  assert.doesNotMatch(sql, /INSERT INTO henvalt\.shopify_app_registry/i);
});

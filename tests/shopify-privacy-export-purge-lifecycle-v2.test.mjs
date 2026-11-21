import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const migration = readFileSync(new URL("../supabase/migrations/202611180026_shopify_privacy_export_purge_lifecycle_v2.sql", import.meta.url), "utf8");

test("purge lifecycle uses a bounded service-only lease with hashed single-use tokens", () => {
  assert.match(migration, /purge_claim_token_sha256/);
  assert.match(migration, /extensions\.digest\(pg_catalog\.convert_to\(v_token, 'UTF8'\), 'sha256'\)/);
  assert.match(migration, /FOR UPDATE OF a SKIP LOCKED/);
  assert.match(migration, /p_lease_seconds NOT BETWEEN 60 AND 900/);
  assert.match(migration, /purge_attempt_count < 10/);
});

test("artifact cannot be marked purged without valid claim and explicit object absence", () => {
  assert.match(migration, /p_object_absence_confirmed IS DISTINCT FROM true/);
  assert.match(migration, /a\.purge_lease_until > pg_catalog\.now\(\)/);
  assert.match(migration, /a\.purge_claim_token_sha256 =/);
  assert.match(migration, /state = 'PURGED'/);
});

test("purge failures remain pending and append auditable evidence", () => {
  assert.match(migration, /state = 'PURGE_PENDING'/);
  assert.match(migration, /'ARTIFACT_PURGED'/);
  assert.match(migration, /'ARTIFACT_PURGE_FAILED'/);
  assert.match(migration, /REVOKE ALL ON FUNCTION henvalt\.claim_shopify_privacy_export_purge_v2/);
  assert.match(migration, /GRANT EXECUTE ON FUNCTION henvalt\.claim_shopify_privacy_export_purge_v2\(integer\)\s+TO service_role/);
});

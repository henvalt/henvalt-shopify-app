import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const migration = readFileSync(new URL("../supabase/migrations/202611170014_shopify_privacy_processing_queue_v2.sql", import.meta.url), "utf8");

test("privacy work is queued only against the verified receipt and immutable store link", () => {
  assert.match(migration, /FOREIGN KEY \(receipt_id\)[\s\S]*shopify_privacy_webhook_deliveries\(id\)/);
  assert.match(migration, /NEW\.connection_id IS NOT NULL[\s\S]*NEW\.tenant_id IS NOT NULL/);
  assert.match(migration, /JOIN henvalt\.shopify_connections sc[\s\S]*sc\.id = r\.connection_id[\s\S]*sc\.app_key = r\.app_key[\s\S]*sc\.shop_domain = r\.shop_domain/);
  assert.doesNotMatch(migration, /tenant_id\s*=\s*r\.tenant_id[\s\S]{0,100}OR\s+sc\.shop_domain/);
});

test("privacy claims are leased, single-use, service-role-only and store only token digests", () => {
  assert.match(migration, /FOR UPDATE OF j SKIP LOCKED/);
  assert.match(migration, /lease_until <= pg_catalog\.now\(\)/);
  assert.match(migration, /claim_token_sha256/);
  assert.match(migration, /extensions\.digest\(pg_catalog\.convert_to\(v_token, 'UTF8'\), 'sha256'\)/);
  assert.match(migration, /GRANT EXECUTE ON FUNCTION henvalt\.claim_shopify_privacy_request_v2\(integer\) TO service_role/);
  assert.match(migration, /REVOKE ALL ON henvalt\.shopify_privacy_processing_jobs_v2[\s\S]*FROM PUBLIC, anon, authenticated, service_role/);
});

test("privacy completion requires processor confirmation and clears the receipt customer identifier", () => {
  assert.match(migration, /p_processor_confirmed IS DISTINCT FROM true/);
  assert.match(migration, /processing_status = 'COMPLETED'[\s\S]*customer_id = NULL/);
  assert.match(migration, /p_retryable AND j\.attempt_count < 10/);
  assert.match(migration, /p_failure_code !~ '\^\[A-Z0-9_\]\{1,64\}\$'/);
});

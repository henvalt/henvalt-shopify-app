import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const migration = readFileSync(new URL("../supabase/migrations/202611170015_shopify_customer_privacy_export_v2.sql", import.meta.url), "utf8");

test("customer privacy export requires a live exact-store receipt claim", () => {
  assert.match(migration, /r\.topic = 'customers\/data_request'/);
  assert.match(migration, /sc\.id = r\.connection_id[\s\S]*sc\.tenant_id = r\.tenant_id[\s\S]*sc\.app_key = r\.app_key[\s\S]*sc\.shop_domain = r\.shop_domain/);
  assert.match(migration, /j\.state = 'CLAIMED'[\s\S]*j\.lease_until > pg_catalog\.now\(\)[\s\S]*j\.claim_token_sha256 = v_claim_hash/);
  assert.match(migration, /c\.shopify_connection_id = v_connection_id[\s\S]*c\.external_customer_reference = v_receipt\.customer_id/);
});

test("customer export includes exact-store linked categories and excludes recipient secrets", () => {
  for (const key of ["sessions", "session_aliases", "pixel_events", "checkouts", "recovery_candidates", "recovery_opportunities", "consent_current", "consent_history", "recovery_interventions", "delivery_attempts", "delivery_permits", "delivery_suppressions", "provider_events", "orders", "refunds", "recovery_attributions", "recovery_fee_measurements"]) {
    assert.ok(migration.includes("'" + key + "'"), "missing export category " + key);
  }
  assert.doesNotMatch(migration, /recipient_fingerprint'\s*,/);
  assert.doesNotMatch(migration, /permit_token_sha256/);
  assert.match(migration, /legacy_scope_review_required', true/);
  assert.match(migration, /completion_eligible', false/);
});

test("customer export is service-role-only and never completes or deletes a request", () => {
  assert.match(migration, /REVOKE ALL ON FUNCTION henvalt\.build_shopify_customer_privacy_export_v2\(uuid,text\)[\s\S]*FROM PUBLIC, anon, authenticated/);
  assert.match(migration, /GRANT EXECUTE ON FUNCTION henvalt\.build_shopify_customer_privacy_export_v2\(uuid,text\)\s+TO service_role/);
  assert.doesNotMatch(migration, /DELETE FROM henvalt\./);
  assert.doesNotMatch(migration, /complete_shopify_privacy_request_v2\(/);
});

import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const migration = readFileSync(new URL("../supabase/migrations/202611170016_shopify_customer_redaction_impact_preview_v2.sql", import.meta.url), "utf8");

test("customer redaction preview requires a live exact-store privacy claim", () => {
  assert.match(migration, /r\.topic IN \('customers\/data_request', 'customers\/redact'\)/);
  assert.match(migration, /sc\.id = r\.connection_id[\s\S]*sc\.tenant_id = r\.tenant_id[\s\S]*sc\.app_key = r\.app_key[\s\S]*sc\.shop_domain = r\.shop_domain/);
  assert.match(migration, /j\.state = 'CLAIMED'[\s\S]*j\.lease_until > pg_catalog\.now\(\)[\s\S]*j\.claim_token_sha256 = v_claim_hash/);
  assert.match(migration, /c\.shopify_connection_id = v_receipt\.connection_id[\s\S]*c\.external_customer_reference = v_receipt\.customer_id/);
});

test("preview inventories exact-store records and flags financial and suppression dependencies", () => {
  for (const key of ["customer_identity", "sessions", "session_aliases", "pixel_events", "checkouts", "recovery_candidates", "recovery_opportunities", "consent_current", "consent_history", "recovery_interventions", "delivery_permits", "delivery_attempts", "delivery_suppressions", "provider_events", "cost_reservations", "orders", "refunds", "attributions", "fee_measurements"]) {
    assert.ok(migration.includes("'" + key + "'"), "missing preview count " + key);
  }
  for (const blocker of ["LEGACY_TENANT_SCOPED_ROWS_NOT_RECONCILED", "RETENTION_POLICY_NOT_APPROVED", "SUPPRESSION_RETENTION_POLICY_NOT_APPROVED", "COST_LEDGER_DETACHMENT_NOT_IMPLEMENTED", "PROVIDER_AUDIT_FK_DETACHMENT_NOT_IMPLEMENTED"]) {
    assert.ok(migration.includes(blocker), "missing execution blocker " + blocker);
  }
});

test("preview is service-role-only, read-only and cannot complete a request", () => {
  assert.match(migration, /REVOKE ALL ON FUNCTION henvalt\.preview_shopify_customer_redaction_v2\(uuid,text\)[\s\S]*FROM PUBLIC, anon, authenticated/);
  assert.match(migration, /GRANT EXECUTE ON FUNCTION henvalt\.preview_shopify_customer_redaction_v2\(uuid,text\)\s+TO service_role/);
  assert.match(migration, /'safe_to_execute', false/);
  assert.match(migration, /'mutations_performed', false/);
  assert.doesNotMatch(migration, /\bDELETE\s+FROM\b|\bUPDATE\s+henvalt\./i);
  assert.doesNotMatch(migration, /complete_shopify_privacy_request_v2\(/);
});

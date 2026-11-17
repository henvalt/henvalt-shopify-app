import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const migration = readFileSync(new URL("../supabase/migrations/202611170018_shopify_customer_redaction_send_guard_v2.sql", import.meta.url), "utf8");
const integration = readFileSync(new URL("./sql/shopify-customer-redaction-send-guard-v2.test.sql", import.meta.url), "utf8");

test("redaction guard is claim-bound and exact-store scoped", () => {
  assert.match(migration, /r\.topic = 'customers\/redact'/);
  assert.match(migration, /sc\.id = r\.connection_id[\s\S]*sc\.tenant_id = r\.tenant_id[\s\S]*sc\.app_key = r\.app_key[\s\S]*sc\.shop_domain = r\.shop_domain/);
  assert.match(migration, /j\.state = 'CLAIMED'[\s\S]*j\.lease_until > pg_catalog\.now\(\)[\s\S]*j\.claim_token_sha256 = v_claim_hash/);
  assert.match(migration, /c\.shopify_connection_id = v_receipt\.connection_id[\s\S]*c\.external_customer_reference = v_receipt\.customer_id/);
});

test("guard serializes permit and send-attempt inserts against activation", () => {
  assert.match(migration, /FOR KEY SHARE/);
  assert.match(migration, /FOR UPDATE[\s\S]*INSERT INTO henvalt\.shopify_customer_redaction_guards_v2/);
  assert.match(migration, /BEFORE INSERT ON henvalt\.shopify_delivery_permits_v2/);
  assert.match(migration, /BEFORE INSERT ON henvalt\.shopify_recovery_send_attempt_v2/);
  assert.match(migration, /ERRCODE = '55000'/);
});

test("guard expires only unconsumed permits and cancels only untouched interventions", () => {
  assert.match(migration, /p\.consumed_at IS NULL[\s\S]*p\.expires_at > pg_catalog\.now\(\)/);
  assert.match(migration, /i\.status = 'READY_FOR_AUTHORIZATION'[\s\S]*NOT EXISTS \([\s\S]*shopify_recovery_send_attempt_v2/);
  assert.match(migration, /a\.status IN \('AUTHORIZED', 'AMBIGUOUS'\)/);
  assert.match(migration, /'safe_to_complete_privacy_request', false/);
  assert.match(migration, /'customer_data_deleted', false/);
});

test("guard preserves suppression, provider, cost and financial records", () => {
  for (const marker of [
    "'suppression_records_mutated', false",
    "'provider_audit_records_mutated', false",
    "'cost_reservations_mutated', false",
    "'order_refund_attribution_fee_records_mutated', false"
  ]) assert.ok(migration.includes(marker));
  assert.doesNotMatch(migration, /\bDELETE\s+FROM\b/i);
  assert.doesNotMatch(migration, /UPDATE\s+henvalt\.shopify_(delivery_suppressions|mailer_provider_events|delivery_cost_reservations|order_refund_adjustments|recovery_attributions|recovery_fee_measurements)/i);
});

test("SQL integration test covers store isolation and blocked authorization", () => {
  assert.match(integration, /redaction-guard-customer-9001/);
  assert.match(integration, /shopify_customer_redaction_guards_v2/);
  assert.match(integration, /new delivery permit was allowed/i);
  assert.match(integration, /new send attempt was allowed/i);
  assert.match(integration, /mismatched claim token/i);
});

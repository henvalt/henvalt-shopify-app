import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const sql = readFileSync(new URL("../supabase/migrations/202611180029_shopify_customer_contact_evidence_v2.sql", import.meta.url), "utf8");

test("contact evidence is exact-store and tied to an existing customer identity", () => {
  assert.match(sql, /FOREIGN KEY \(customer_identity_id,tenant_id,shopify_connection_id\)[\s\S]*?REFERENCES henvalt\.shopify_customer_identity_v2\(id,tenant_id,shopify_connection_id\)/);
  assert.match(sql, /UNIQUE \(shopify_connection_id,customer_identity_id\)/);
  assert.match(sql, /FOREIGN KEY \(evidence_id,tenant_id,shopify_connection_id,customer_identity_id\)/);
});

test("evidence stores no contact value, address, phone, or token", () => {
  assert.match(sql, /contact_available boolean NOT NULL/);
  assert.match(sql, /country_code text/);
  assert.doesNotMatch(sql, /email_address|recipient_email|street_address|postal_code|phone_number|access_token text/i);
  assert.match(sql, /contact_value_stored',false/);
  assert.match(sql, /address_fields_stored',false/);
});

test("only fresh, active exact-store lookups can update evidence", () => {
  assert.match(sql, /p_observed_at < pg_catalog\.now\(\)-interval '5 minutes'/);
  assert.match(sql, /p_observed_at > pg_catalog\.now\(\)\+interval '1 minute'/);
  assert.match(sql, /v_connection\.active IS DISTINCT FROM true/);
  assert.match(sql, /v_connection\.tenant_status<>'ACTIVE'/);
  assert.match(sql, /v_connection\.lifecycle_status<>'active'/);
  assert.match(sql, /p_observed_at>v_existing_at/);
});

test("replayed lookup IDs cannot overwrite evidence with different facts", () => {
  assert.match(sql, /ON CONFLICT\(shopify_connection_id,lookup_id\) DO NOTHING/);
  assert.match(sql, /LOOKUP_ID_REPLAY_MISMATCH/);
});

test("recording evidence is service-only and never authorizes a send", () => {
  assert.match(sql, /REVOKE ALL ON FUNCTION henvalt\.record_shopify_customer_contact_evidence_v2/);
  assert.match(sql, /GRANT EXECUTE ON FUNCTION henvalt\.record_shopify_customer_contact_evidence_v2[\s\S]*TO service_role/);
  assert.match(sql, /'send_authorized',false/);
});

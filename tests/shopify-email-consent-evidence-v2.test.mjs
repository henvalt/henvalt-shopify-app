import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const migration = readFileSync("supabase/migrations/202611170003_shopify_email_consent_evidence_v2.sql", "utf8");
const ingress = readFileSync("supabase/functions/henvalt-shopify-webhook-ingress/index.ts", "utf8");
const oauth = readFileSync("supabase/functions/henvalt-shopify-oauth-v2/index.ts", "utf8");

test("V2 email consent is sourced only from the signed Shopify consent webhook", () => {
  assert.match(oauth, /customers_email_marketing_consent\/update/);
  assert.match(ingress, /project_verified_shopify_email_consent_v2/);
  assert.match(migration, /d\.topic <> 'customers_email_marketing_consent\/update'/);
  assert.match(migration, /raw_body_sha256/);
  assert.match(migration, /RECEIPT_BODY_MISMATCH/);
});

test("consent evidence is exact-store, pseudonymous, and server-only", () => {
  assert.match(migration, /UNIQUE \(shopify_connection_id, customer_identity_id\)/);
  assert.match(migration, /UNIQUE \(shopify_connection_id, source_delivery_id\)/);
  assert.match(migration, /FOREIGN KEY \(customer_identity_id, tenant_id, shopify_connection_id\)/);
  assert.match(migration, /REVOKE ALL ON henvalt\.shopify_customer_email_consent_v2 FROM PUBLIC, anon, authenticated, service_role/);
  assert.match(migration, /recipient_pii_stored',false/);
  assert.doesNotMatch(migration, /email_address|raw_payload|email_normalized/);
});

test("unknown, pending, revoked, invalid and redacted consent cannot be treated as subscribed", () => {
  assert.match(migration, /'SUBSCRIBED','NOT_SUBSCRIBED','UNSUBSCRIBED','PENDING','INVALID','REDACTED','UNKNOWN'/);
  assert.match(migration, /CASE WHEN v_consent_at IS NULL THEN 'UNKNOWN' ELSE v_state END/);
  assert.match(migration, /marketing_state='UNKNOWN'/);
  assert.match(migration, /v_consent_at>=v_existing_at/);
});

test("checkout jurisdiction is explicitly nullable and must remain fail-closed downstream", () => {
  assert.match(migration, /jurisdiction_country_code text/);
  assert.match(migration, /jurisdiction_country_code IS NULL OR jurisdiction_country_code ~ '\^\[A-Z\]\{2\}\$'/);
});

import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const read = (path) => readFileSync(new URL(path, import.meta.url), "utf8");
const opportunities = read("../supabase/migrations/202611180028_shopify_general_recovery_opportunities_v2.sql");
const permits = read("../supabase/migrations/202611170006_shopify_single_use_delivery_authorization_v2.sql");
const resolver = read("../supabase/migrations/202611170007_shopify_contact_resolution_and_delivery_v2.sql");
const reservations = read("../supabase/migrations/202611170008_shopify_delivery_cost_reservations_v2.sql");
const consent = read("../supabase/migrations/202611170003_shopify_email_consent_evidence_v2.sql");
const jurisdiction = read("../supabase/migrations/202611170004_shopify_checkout_jurisdiction_projection_v2.sql");
const gate = read("../docs/shopify-pixel-contact-jurisdiction-delivery-gate-v2.md");

test("pixel opportunity source shape cannot masquerade as checkout identity", () => {
  assert.match(opportunities, /candidate_id IS NULL[\s\S]*?checkout_identity_id IS NULL[\s\S]*?pixel_candidate_id IS NOT NULL/);
  assert.match(opportunities, /'REVIEW_REQUIRED' AS initial_status/);
  assert.doesNotMatch(opportunities, /'CONTACT_RESOLUTION_PENDING' AS initial_status/);
});

test("existing resolver and both permit stages remain checkout-only", () => {
  for (const sql of [resolver, permits]) {
    assert.match(sql, /JOIN henvalt\.shopify_checkout_recovery_candidate_v2 c/);
    assert.match(sql, /JOIN henvalt\.shopify_checkout_identity_v2 ch/);
    assert.match(sql, /jurisdiction_country_code/);
    assert.match(sql, /marketing_state/);
  }
  assert.match(permits, /consumed_at IS NOT NULL[\s\S]*?PERMIT_ALREADY_USED/);
  assert.match(permits, /PERMIT_EXPIRED/);
});

test("consent remains exact-store and timestamp evidence, not pixel marketing consent", () => {
  assert.match(consent, /UNIQUE \(shopify_connection_id, customer_identity_id\)/);
  assert.match(consent, /v_consent_at IS NULL[\s\S]*?'UNKNOWN'/);
  assert.match(consent, /v_consent_at>v_existing_at/);\n  assert.match(consent, /v_consent_at=v_existing_at[\\s\\S]*?UNKNOWN/);
  assert.match(gate, /pixel marketing signal never authorize email/i);
});

test("jurisdiction source remains verified checkout address, never inferred browser context", () => {
  assert.match(jurisdiction, /shipping_address/);
  assert.match(jurisdiction, /billing_address/);
  assert.match(jurisdiction, /address_fields_stored',false/);
  assert.match(gate, /Store locale, currency, browser locale, IP geolocation and inferred country are not acceptable substitutes/);
});

test("cost reservation is atomic and merchant-wide across stores", () => {
  assert.match(reservations, /FROM henvalt\.billing_accounts[\s\S]*?FOR UPDATE/);
  assert.match(reservations, /WHERE r\.tenant_id=NEW\.tenant_id/);
  assert.match(reservations, /r\.status IN \('RESERVED','SETTLED'\)/);
  assert.match(reservations, /AFTER INSERT ON henvalt\.shopify_recovery_send_attempt_v2/);
  assert.match(reservations, /WHEN NEW\.status='AMBIGUOUS' THEN 'RESERVED'/);
  assert.match(gate, /must call this same reservation mechanism exactly once/i);
});

test("delivery design forbids PII handoff and blind retry of ambiguous sends", () => {
  assert.match(gate, /recipient email stays transient inside the trusted delivery Edge Function/i);
  assert.match(gate, /n8n receives opaque IDs and status only/i);
  assert.match(gate, /AMBIGUOUS and must not be automatically resent/i);
  assert.match(gate, /Keep the existing three workflows/i);
});

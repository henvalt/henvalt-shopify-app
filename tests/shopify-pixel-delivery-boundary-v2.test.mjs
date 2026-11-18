import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const read = (path) => readFileSync(new URL(path, import.meta.url), "utf8");
const opportunities = read("../supabase/migrations/202611180028_shopify_general_recovery_opportunities_v2.sql");
const permits = read("../supabase/migrations/202611170006_shopify_single_use_delivery_authorization_v2.sql");
const delivery = read("../supabase/functions/henvalt-shopify-contact-delivery-v2/index.ts");
const contact = read("../supabase/functions/henvalt-shopify-contact-evidence-v2/index.ts");
const evidence = read("../supabase/migrations/202611180031_shopify_contact_jurisdiction_region_v2.sql");
const reservations = read("../supabase/migrations/202611170008_shopify_delivery_cost_reservations_v2.sql");

function functionBody(source, name, nextName) {
  const start = source.indexOf(`CREATE OR REPLACE FUNCTION henvalt.${name}(`);
  assert.notEqual(start, -1, `missing function ${name}`);
  const end = source.indexOf(`CREATE OR REPLACE FUNCTION henvalt.${nextName}(`, start + 1);
  return source.slice(start, end === -1 ? source.length : end);
}

test("cart and browse opportunity rows are structurally distinct from checkout rows", () => {
  assert.match(opportunities, /opportunity_type IN \('ABANDONED_CART','BROWSE_ABANDONMENT'\)[\s\S]*?candidate_id IS NULL[\s\S]*?checkout_identity_id IS NULL[\s\S]*?source_delivery_id IS NULL[\s\S]*?pixel_candidate_id IS NOT NULL/);
  assert.match(opportunities, /'REVIEW_REQUIRED' AS initial_status/);
  assert.match(opportunities, /'delivery_authorized',false/);
  assert.match(opportunities, /'interventions_created',false/);
});

test("permit issuance and consumption remain checkout-only at both authorization stages", () => {
  const issue = functionBody(permits, "issue_shopify_delivery_permit_v2", "consume_shopify_delivery_permit_v2");
  const consume = functionBody(permits, "consume_shopify_delivery_permit_v2", "__no_next_function__");
  for (const body of [issue, consume]) {
    assert.match(body, /JOIN henvalt\.shopify_checkout_recovery_candidate_v2 c/);
    assert.match(body, /JOIN henvalt\.shopify_checkout_identity_v2 ch/);
    assert.match(body, /ch\.id=opp\.checkout_identity_id/);
    assert.match(body, /consent\.marketing_state/);
    assert.match(body, /jurisdiction_country_code/);
  }
  assert.match(consume, /PERMIT_ALREADY_USED/);
  assert.match(consume, /PERMIT_EXPIRED/);
});

test("delivery Edge Function accepts an intervention, not a pixel candidate or browser-supplied recipient", () => {
  assert.match(delivery, /input\.intervention_id/);
  assert.doesNotMatch(delivery, /input\.(?:pixel_candidate_id|customer_identity_id|recipient_email)/);
  assert.match(delivery, /resolve_shopify_delivery_context_v2/);
  assert.match(delivery, /shopifyEmail\(shop,access,customerRef\)/);
  assert.match(delivery, /issue_shopify_delivery_permit_v2/);
  assert.match(delivery, /consume_shopify_delivery_permit_v2/);
  assert.match(delivery, /https:\/\/api\.mailersend\.com\/v1\/email/);
  assert.doesNotMatch(delivery, /console\.(?:log|info|warn|error)\([^\n]*email/i);
});

test("contact evidence resolver never returns recipient email or grants send authority", () => {
  assert.ok(contact.includes("customer(id: $id) { id email defaultAddress { countryCodeV2 provinceCode } }"));
  assert.match(contact, /record_shopify_customer_contact_evidence_v3/);
  assert.match(contact, /send_authorized:false/);
  assert.match(contact, /recipient_email_returned:false/);
  assert.doesNotMatch(contact, /recipient_email_returned:true/);
  assert.doesNotMatch(contact, /email:\s*customer\.email/);
});

test("contact evidence stores bounded country and region facts, not address or contact values", () => {
  assert.match(evidence, /ADD COLUMN IF NOT EXISTS region_code text/);
  assert.ok(evidence.includes("region_code !~ '^[A-Z0-9-]{1,12}$'"));
  assert.match(evidence, /contact_value_stored',false/);
  assert.match(evidence, /address_fields_stored',false/);
  assert.match(evidence, /GRANT EXECUTE ON FUNCTION henvalt\.record_shopify_customer_contact_evidence_v3[\s\S]*?TO service_role/);
  assert.doesNotMatch(evidence, /email_address|recipient_email|street_address|postal_code/);
});

test("cart/browse must reuse the existing atomic merchant-wide reservation mechanism", () => {
  assert.match(reservations, /FROM henvalt\.billing_accounts[\s\S]*?FOR UPDATE/);
  assert.match(reservations, /WHERE r\.tenant_id=NEW\.tenant_id/);
  assert.match(reservations, /r\.status IN \('RESERVED','SETTLED'\)/);
  assert.match(reservations, /AFTER INSERT ON henvalt\.shopify_recovery_send_attempt_v2/);
});

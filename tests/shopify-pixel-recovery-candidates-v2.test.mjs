import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const migration = readFileSync(
  new URL("../supabase/migrations/202611180027_shopify_pixel_recovery_candidates_v2.sql", import.meta.url),
  "utf8",
);
const inboxMigration = readFileSync(
  new URL("../supabase/migrations/202611160008_shopify_pixel_event_inbox_v2.sql", import.meta.url),
  "utf8",
);
const opportunityMigration = readFileSync(
  new URL("../supabase/migrations/202611180028_shopify_general_recovery_opportunities_v2.sql", import.meta.url),
  "utf8",
);
const deliveryMigration = readFileSync(
  new URL("../supabase/migrations/202611170006_shopify_single_use_delivery_authorization_v2.sql", import.meta.url),
  "utf8",
);
const collector = readFileSync(
  new URL("../cloudflare/pixel-collector.js", import.meta.url),
  "utf8",
);

test("pixel inbox retains only bounded product and cart context under analytics consent", () => {
  assert.match(inboxMigration, /IF v_analytics_allowed THEN[\s\S]*?'product',[\s\S]*?'cart_line'/);
  assert.match(inboxMigration, /'product_title'[\s\S]*?'unit_price_amount'[\s\S]*?'line_total_amount'/);
  assert.match(inboxMigration, /'price_currency'[\s\S]*?'currency'/);
  assert.match(inboxMigration, /ELSE '\{\}'::jsonb END/);
  assert.match(collector, /product_id: validId\(payload\.cart_line\.product_id, 200\)/);
  assert.match(collector, /line_total_amount: typeof payload\.cart_line\.line_total_amount/);
});

test("cart and browse candidates are exact-store constrained through every identity foreign key", () => {
  assert.match(migration, /FOREIGN KEY \(shopify_connection_id, tenant_id\)[\s\S]*?REFERENCES henvalt\.shopify_connections\(id, tenant_id\)/);
  assert.match(migration, /FOREIGN KEY \(session_identity_id, tenant_id, shopify_connection_id\)[\s\S]*?REFERENCES henvalt\.shopify_session_identity_v2/);
  assert.match(migration, /FOREIGN KEY \(customer_identity_id, tenant_id, shopify_connection_id\)[\s\S]*?REFERENCES henvalt\.shopify_customer_identity_v2/);
  assert.match(migration, /FOREIGN KEY \(source_inbox_event_id, tenant_id, shopify_connection_id\)[\s\S]*?REFERENCES henvalt\.shopify_pixel_event_inbox_v2/);
  assert.match(migration, /UNIQUE \(shopify_connection_id, idempotency_key\)/);
});

test("candidate worker reads only processed analytics-consented events from active exact stores", () => {
  assert.match(migration, /e\.status = 'PROCESSED'[\s\S]*?e\.analytics_processing_allowed IS TRUE/);
  assert.match(migration, /s\.shopify_connection_id = e\.shopify_connection_id/);
  assert.match(migration, /sc\.id = e\.shopify_connection_id[\s\S]*?sc\.active IS TRUE/);
  assert.match(migration, /ar\.lifecycle_status = 'active'[\s\S]*?t\.status = 'ACTIVE'/);
});

test("cart and browse eligibility have separate intent and same-store suppression gates", () => {
  assert.match(migration, /'product_added_to_cart'[\s\S]*?'product_viewed'/);
  assert.match(migration, /a\.repeat_view_count >= 2/);
  assert.match(migration, /'product_removed_from_cart', 'checkout_started'/);
  assert.match(migration, /later\.shopify_connection_id = c\.shopify_connection_id/);
  assert.match(migration, /later\.shopify_connection_id = a\.shopify_connection_id/);
  assert.match(migration, /'ABANDONED_CART'[\s\S]*?'BROWSE_ABANDONMENT'/);
});

test("candidate stage cannot send, authorize delivery, or bill", () => {
  assert.match(migration, /'delivery_authorized', false/);
  assert.match(migration, /'marketing_consent_checked_for_send', false/);
  assert.doesNotMatch(migration, /INSERT\s+INTO\s+henvalt\.shopify_recovery_opportunity_v2/i);
  assert.doesNotMatch(migration, /mailer|send_attempt|billing_measurement|revenue_ledger/i);
});

test("generalized opportunity model preserves one exact-store source shape", () => {
  assert.match(opportunityMigration, /candidate_id DROP NOT NULL/);
  assert.match(opportunityMigration, /checkout_identity_id DROP NOT NULL/);
  assert.match(opportunityMigration, /source_delivery_id DROP NOT NULL/);
  assert.match(opportunityMigration, /pixel_candidate_id uuid/);
  assert.match(opportunityMigration, /ABANDONED_CHECKOUT', 'ABANDONED_CART', 'BROWSE_ABANDONMENT/);
  assert.match(opportunityMigration, /FOREIGN KEY \(pixel_candidate_id,tenant_id,shopify_connection_id\)/);
  assert.match(opportunityMigration, /'pixel:'\|\|s\.idempotency_key/);
});

test("cart and browse promotion creates metadata only, not interventions or delivery permits", () => {
  assert.match(opportunityMigration, /promote_shopify_pixel_recovery_candidates_v2/);
  assert.match(opportunityMigration, /'interventions_created',false/);
  assert.match(opportunityMigration, /'delivery_authorized',false/);
  assert.doesNotMatch(opportunityMigration, /INSERT\s+INTO\s+henvalt\.shopify_recovery_intervention_v2/i);
  assert.match(deliveryMigration, /JOIN henvalt\.shopify_checkout_recovery_candidate_v2 c/);
  assert.match(deliveryMigration, /JOIN henvalt\.shopify_checkout_identity_v2 ch/);
});


test("pixel opportunities remain review-gated even when a customer identity is present", () => {
  assert.match(opportunityMigration, /'REVIEW_REQUIRED' AS initial_status/);
  assert.doesNotMatch(opportunityMigration, /CASE WHEN c\.customer_identity_id IS NOT NULL[\s\S]*?CONTACT_RESOLUTION_PENDING/);
  assert.match(opportunityMigration, /pixel customer identity is not proof of a deliverable contact/);
});

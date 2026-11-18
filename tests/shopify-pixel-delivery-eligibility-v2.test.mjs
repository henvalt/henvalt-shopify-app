import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
const migration=readFileSync(new URL("../supabase/migrations/202611180032_shopify_pixel_delivery_eligibility_v2.sql",import.meta.url),"utf8");
const policyDoc=readFileSync(new URL("../docs/shopify-pixel-delivery-eligibility-v2.md",import.meta.url),"utf8");
test("pixel jurisdiction policy is explicit, versioned, unseeded, and legal-review referenced",()=>{
 assert.match(migration,/CREATE TABLE IF NOT EXISTS henvalt\.shopify_pixel_delivery_jurisdiction_policy_v2/);
 assert.match(migration,/legal_review_reference text NOT NULL/);
 assert.match(migration,/policy_status IN \('DRAFT','APPROVED','SUSPENDED','EXPIRED'\)/);
 assert.match(migration,/evidence_source = 'SHOPIFY_CUSTOMER_DEFAULT_ADDRESS'/);
 assert.match(migration,/max_contact_evidence_age <= interval '15 minutes'/);
 assert.doesNotMatch(migration,/INSERT INTO henvalt\.shopify_pixel_delivery_jurisdiction_policy_v2/);
});
test("eligibility assessment is service-only, exact-store and fail-closed",()=>{
 assert.match(migration,/assess_shopify_pixel_delivery_eligibility_v2\(\s*p_opportunity_id uuid/);
 assert.match(migration,/request\.jwt\.claim\.role/);
 assert.match(migration,/JOIN henvalt\.shopify_pixel_recovery_candidate_v2 c[\s\S]*?c\.tenant_id=o\.tenant_id[\s\S]*?c\.shopify_connection_id=o\.shopify_connection_id/);
 assert.match(migration,/marketing_state='SUBSCRIBED'[\s\S]*?consent\.observed_at>=pg_catalog\.now\(\)-v_policy\.max_consent_evidence_age/);
 assert.match(migration,/shopify_delivery_suppressions_v2/);
 assert.match(migration,/shopify_customer_redaction_guards_v2/);
 assert.match(migration,/shopify_order_identity_v2/);
 assert.match(migration,/policy_status='APPROVED'/);
 assert.ok(migration.includes("p.region_code IS NOT DISTINCT FROM v_contact.region_code"));
 assert.ok(migration.includes("p.region_code IS NULL AND p.require_region IS FALSE"));
 assert.match(migration,/policy_status <> 'APPROVED' OR approved_at IS NOT NULL/);
});
test("eligibility assessment cannot create or authorize delivery",()=>{
 const start=migration.indexOf("CREATE OR REPLACE FUNCTION henvalt.assess_shopify_pixel_delivery_eligibility_v2");
 const end=migration.indexOf("REVOKE ALL ON FUNCTION henvalt.assess_shopify_pixel_delivery_eligibility_v2",start);
 const body=migration.slice(start,end);
 assert.doesNotMatch(body,/INSERT INTO henvalt\.(shopify_recovery_intervention_v2|shopify_delivery_permits_v2|shopify_recovery_send_attempt_v2)/);
 assert.match(body,/delivery_authorized',false/);
 assert.match(body,/permit_issued',false/);
 assert.match(body,/intervention_created',false/);
 assert.match(body,/send_attempt_created',false/);
 assert.match(body,/recipient_email_returned',false/);
});
test("engineering boundary records future delivery-time requirements",()=>{
 assert.match(policyDoc,/Delivery-time email must be re-resolved from the exact Shopify customer GID/);
 assert.match(policyDoc,/atomic merchant-wide cost-reservation trigger/);
});

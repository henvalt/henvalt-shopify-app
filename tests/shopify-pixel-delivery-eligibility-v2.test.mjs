import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
const migration=readFileSync(new URL("../supabase/migrations/202611180032_shopify_pixel_delivery_eligibility_v2.sql",import.meta.url),"utf8");
const policyDoc=readFileSync(new URL("../docs/shopify-pixel-delivery-eligibility-v2.md",import.meta.url),"utf8");
const context=readFileSync(new URL("../supabase/migrations/202611180035_shopify_pixel_delivery_context_v2.sql",import.meta.url),"utf8");
const finalGate=readFileSync(new URL("../supabase/migrations/202611180036_shopify_pixel_provider_submission_gate_v2.sql",import.meta.url),"utf8");
const edge=readFileSync(new URL("../supabase/functions/henvalt-shopify-pixel-delivery-v2/index.ts",import.meta.url),"utf8");
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
 assert.match(policyDoc,/future delivery-time Shopify Admin re-resolution of email and marketing consent/);
 assert.match(policyDoc,/atomic merchant-wide cost-reservation trigger/);
});

test("pixel delivery authenticates its dedicated bearer before parsing or any tenant/store lookup",()=>{
 const edge=readFileSync(new URL("../supabase/functions/henvalt-shopify-pixel-delivery-v2/index.ts",import.meta.url),"utf8");
 const handler=edge.slice(edge.indexOf("Deno.serve("));
 const auth=handler.indexOf('if(!bearer||!equal(bearer,DELIVERY_AUTH_TOKEN))');
 const readiness=handler.indexOf('if(!MAILERSEND_V2_EVENTS_READY)');
 const parse=handler.indexOf('parseJsonLimited(req');
 const firstLookup=handler.indexOf('rpc("resolve_shopify_recovery_message_context_v2"');
 assert.match(edge,/HENVALT_PIXEL_DELIVERY_AUTH_TOKEN/);
 assert.ok(auth>=0&&readiness>auth&&parse>readiness&&firstLookup>parse);
 assert.match(handler,/if\(!bearer\|\|!equal\(bearer,DELIVERY_AUTH_TOKEN\)\)return json\(401/);
});

test("pixel context and final gate bind opportunity, customer, tenant and exact Shopify store lineage",()=>{
 for(const pattern of [
  /ci\.id=o\.customer_identity_id AND ci\.tenant_id=o\.tenant_id[\s\S]*?ci\.shopify_connection_id=o\.shopify_connection_id/,
  /sc\.id=o\.shopify_connection_id AND sc\.tenant_id=o\.tenant_id/,
  /sp\.tenant_id=o\.tenant_id AND sp\.shopify_connection_id=o\.shopify_connection_id/
 ]) assert.match(context,pattern);
 for(const pattern of [
  /permit_row\.tenant_id=attempt_row\.tenant_id/,
  /permit_row\.shopify_connection_id=attempt_row\.shopify_connection_id/,
  /reservation_row\.tenant_id=attempt_row\.tenant_id/,
  /reservation_row\.shopify_connection_id=attempt_row\.shopify_connection_id/,
  /assessment:=henvalt\.assess_shopify_pixel_delivery_eligibility_v2\(v_attempt\.opportunity_id\)/
 ]) assert.match(finalGate,pattern);
 assert.ok(edge.indexOf('resolve_shopify_pixel_delivery_context_v2')<edge.indexOf('authorize_shopify_pixel_provider_submission_v2'));
});
test("pixel missing or incorrect dedicated bearer and disabled send interlock stop before request parsing or lookups",()=>{
 const handler=edge.slice(edge.indexOf("Deno.serve("));
 const configured=handler.indexOf('if(!SUPABASE_URL||!SERVICE_ROLE_KEY||!DELIVERY_AUTH_TOKEN)');
 const auth=handler.indexOf('if(!bearer||!equal(bearer,DELIVERY_AUTH_TOKEN))');
 const readiness=handler.indexOf('if(!MAILERSEND_V2_EVENTS_READY)');
 const parse=handler.indexOf('parseJsonLimited(req');
 const lookup=handler.indexOf('resolve_shopify_recovery_message_context_v2');
 const provider=handler.indexOf('https://api.mailersend.com/v1/email');
 assert.ok(configured>=0&&auth>configured&&readiness>auth&&parse>readiness&&lookup>parse&&provider>lookup);
 assert.match(handler,/return json\(503,\{error:"pixel_delivery_not_configured"\}\)/);
 assert.match(handler,/return json\(401,\{error:"unauthorized"\}\)/);
});

import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
const migration=readFileSync(new URL("../supabase/migrations/202611180033_shopify_admin_marketing_consent_lookup_v2.sql",import.meta.url),"utf8");
const edge=readFileSync(new URL("../supabase/functions/henvalt-shopify-contact-evidence-v2/index.ts",import.meta.url),"utf8");
const workflow=readFileSync(new URL("../.github/workflows/shopify-identity-v2-validation.yml",import.meta.url),"utf8");
test("Admin API consent evidence is append-only, exact-store, private and replay-safe",()=>{
 assert.match(migration,/CREATE TABLE IF NOT EXISTS henvalt\.shopify_customer_marketing_consent_lookup_evidence_v2/);
 assert.match(migration,/UNIQUE \(shopify_connection_id,lookup_id\)/);
 assert.match(migration,/FOREIGN KEY \(customer_identity_id,tenant_id,shopify_connection_id\)/);
 assert.match(migration,/REVOKE ALL ON henvalt\.shopify_customer_marketing_consent_lookup_evidence_v2[\s\S]*?service_role/);
 assert.match(migration,/LOOKUP_ID_REPLAY_MISMATCH/);
 assert.match(migration,/recipient_pii_stored',false/);
});
test("recording requires service role and bounded fresh observations",()=>{
 assert.match(migration,/request\.jwt\.claim\.role[\s\S]*?service_role_required/);
 assert.match(migration,/p_observed_at<pg_catalog\.now\(\)-interval '5 minutes'/);
 assert.match(migration,/p_observed_at>pg_catalog\.now\(\)\+interval '1 minute'/);
});
test("eligibility requires fresh Admin API SUBSCRIBED and invalidates on any later webhook",()=>{
 assert.match(migration,/FRESH_ADMIN_API_SUBSCRIBED_CONSENT_REQUIRED/);
 assert.match(migration,/marketing_state<>'SUBSCRIBED'/);
 assert.match(migration,/observed_at<pg_catalog\.now\(\)-interval '5 minutes'/);
 assert.match(migration,/CONSENT_WEBHOOK_AFTER_ADMIN_LOOKUP/);
 assert.match(migration,/e\.received_at>v_consent\.observed_at/);
});
test("trusted resolver queries and records Shopify consent without persisting recipient email",()=>{
 assert.match(edge,/emailMarketingConsent \{ marketingState consentUpdatedAt \}/);
 assert.match(edge,/record_shopify_customer_marketing_consent_lookup_v2/);
 assert.match(edge,/marketing_consent_state:marketingState/);
 assert.match(edge,/recipient_email_returned:false/);
 assert.doesNotMatch(edge,/p_email|customer_email|email_address/i);
});
test("CI includes migration 033 and the new contract test",()=>{
 assert.match(workflow,/shopify-admin-marketing-consent-lookup-v2\.test\.mjs/);
 assert.match(workflow,/202611180033_shopify_admin_marketing_consent_lookup_v2\.sql/);
});

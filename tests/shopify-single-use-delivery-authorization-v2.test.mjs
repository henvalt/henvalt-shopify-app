import test from "node:test";
import assert from "node:assert/strict";
import {readFileSync} from "node:fs";

const migration=readFileSync("supabase/migrations/202611170006_shopify_single_use_delivery_authorization_v2.sql","utf8");
const deliveryContract=readFileSync("docs/shopify-single-use-delivery-authorization-v2.md","utf8");
const contactContract=readFileSync("docs/shopify-v2-contact-consent-delivery-contract.md","utf8");

test("delivery permit is opaque, short-lived, single-use and hash-only at rest",()=>{assert.match(migration,/jurisdiction_country_code IS NULL/);
 assert.match(migration,/permit_token_sha256 text NOT NULL UNIQUE/);
 assert.match(migration,/extensions\.digest\(pg_catalog\.convert_to\(v_token,'UTF8'\),'sha256'\)/);
 assert.match(migration,/pg_catalog\.now\(\)\+interval '3 minutes'/);
 assert.match(migration,/consumed_at IS NULL/);
 assert.match(migration,/PERMIT_ALREADY_USED/);
 assert.match(migration,/PERMIT_EXPIRED/);
 assert.doesNotMatch(migration,/recipient_email\s+(text|varchar)/i);
});

test("authorization is bound to the exact Shopify store and current order/consent/suppression state",()=>{
 for(const value of [
  "shopify_connection_id","shopify_app_registry","shopify_customer_email_consent_v2",
  "jurisdiction_country_code","shopify_order_identity_v2","shopify_delivery_suppressions_v2",
  "shopify_checkout_token","RECIPIENT_SUPPRESSED","SAME_STORE_ORDER_EXISTS",
  "CURRENT_EMAIL_CONSENT_REQUIRED","APP_STORE_OR_TENANT_INACTIVE"
 ]) assert.ok(migration.includes(value),value);
 assert.match(migration,/FOR UPDATE OF i,opp,c,ch,sc,ar,t,consent,pr,sp,ba/);
});

test("provider, exact-store sender and merchant billing entitlement must be active",()=>{
 assert.match(migration,/shopify_sender_profiles_v2/);
 assert.match(migration,/verified_at IS NULL/);
 assert.match(migration,/provider_status<>'ACTIVE'/);
 assert.match(migration,/billing_status<>'ACTIVE'/);
 assert.match(migration,/test_mode IS DISTINCT FROM false/);
 assert.match(migration,/henvalt_percentage<=0/);
 assert.match(migration,/monthly_email_limit/);
 assert.match(migration,/MERCHANT_MONTHLY_EMAIL_CAP_REACHED/);
});

test("permit consumption rechecks every critical gate and creates one idempotent send attempt",()=>{
 const consume=migration.slice(migration.indexOf("CREATE OR REPLACE FUNCTION henvalt.consume_shopify_delivery_permit_v2"));
 for(const value of [
  "DELIVERY_GATE_CHANGED","ORDER_OR_SUPPRESSION_GATE_CHANGED",
  "MERCHANT_MONTHLY_EMAIL_CAP_REACHED","ON CONFLICT(shopify_connection_id,idempotency_key) DO NOTHING",
  "PERMIT_ALREADY_USED","PERMIT_EXPIRED","consumed_at=pg_catalog.now()"
 ]) assert.ok(consume.includes(value),value);
 assert.match(migration,/REVOKE ALL ON FUNCTION henvalt\.issue_shopify_delivery_permit_v2[\s\S]*?FROM PUBLIC,anon,authenticated/);
 assert.match(migration,/GRANT EXECUTE ON FUNCTION henvalt\.consume_shopify_delivery_permit_v2\(text\)[\s\S]*?TO service_role/);
});

test("delivery keeps recipient email out of logs and the legacy provider route",()=>{
 assert.match(deliveryContract,/No recipient email in Postgres, n8n execution data, browser responses or logs/);
 assert.match(deliveryContract,/No send authorization from the legacy MailerSend endpoint/);
 assert.match(contactContract,/Do not place raw Shopify payloads, OAuth tokens, Vault secrets or customer email in AI prompts or general diagnostic logs/);
});

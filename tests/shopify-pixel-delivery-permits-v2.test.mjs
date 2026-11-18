import test from "node:test";
import assert from "node:assert/strict";
import {readFileSync} from "node:fs";
const sql=readFileSync(new URL("../supabase/migrations/202611180034_shopify_pixel_delivery_permits_v2.sql",import.meta.url),"utf8");
const checkout=readFileSync(new URL("../supabase/migrations/202611170006_shopify_single_use_delivery_authorization_v2.sql",import.meta.url),"utf8");
test("pixel permits are a distinct exact-opportunity capability, not checkout intervention permits",()=>{
 assert.match(sql,/shopify_pixel_delivery_permits_v2/);
 assert.match(sql,/shopify_pixel_send_attempts_v2/);
 assert.match(sql,/UNIQUE\(opportunity_id\)/);
 assert.match(sql,/v2-pixel-opportunity:/);
 assert.doesNotMatch(sql,/checkout_identity_id|checkout_token|intervention_id/);
 assert.match(sql,/expires_at[\s\S]*interval '2 minutes'/);
});
test("pixel permit issue and consume are service-only, single-use and re-assess gates",()=>{
 assert.match(sql,/issue_shopify_pixel_delivery_permit_v2/);
 assert.match(sql,/consume_shopify_pixel_delivery_permit_v2/);
 assert.match(sql,/PERMIT_ALREADY_USED/);
 assert.match(sql,/PERMIT_EXPIRED/);
 assert.match(sql,/assess_shopify_pixel_delivery_eligibility_v2/);
 assert.match(sql,/RECIPIENT_SUPPRESSION_CHANGED/);
 assert.match(sql,/GRANT EXECUTE ON FUNCTION henvalt\.consume_shopify_pixel_delivery_permit_v2\(text\) TO service_role/);
});
test("pixel send attempt has atomic merchant-wide cost reservation and terminal state accounting",()=>{
 assert.match(sql,/FROM henvalt\.billing_accounts WHERE tenant_id=NEW\.tenant_id FOR UPDATE/);
 assert.match(sql,/shopify_delivery_cost_reservations_v2/);
 assert.match(sql,/CREATE OR REPLACE FUNCTION henvalt\\.reserve_shopify_delivery_cost_v2[\\s\\S]*?shopify_pixel_delivery_cost_reservations_v2/);
 assert.match(sql,/CREATE OR REPLACE FUNCTION henvalt\\.reserve_shopify_pixel_delivery_cost_v2[\\s\\S]*?shopify_delivery_cost_reservations_v2/);
 assert.match(sql,/shopify_pixel_delivery_cost_reservations_v2/);
 assert.match(sql,/usage_cap_amount/);
 assert.match(sql,/monthly_email_limit/);
 assert.match(sql,/WHEN NEW\.status='SUBMITTED' THEN 'SETTLED'/);
 assert.match(sql,/WHEN NEW\.status='FAILED' THEN 'RELEASED'/);
 assert.match(sql,/WHEN NEW\.status='AMBIGUOUS' THEN 'RESERVED'/);
});
test("checkout permit implementation remains unchanged and checkout-only",()=>{
 assert.match(checkout,/JOIN henvalt\.shopify_checkout_recovery_candidate_v2 c/);
 assert.match(checkout,/JOIN henvalt\.shopify_checkout_identity_v2 ch/);
 assert.doesNotMatch(sql,/shopify_checkout_recovery_candidate_v2|shopify_checkout_identity_v2/);
});

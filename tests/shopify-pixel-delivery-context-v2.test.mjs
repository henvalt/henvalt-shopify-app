import test from "node:test";
import assert from "node:assert/strict";
import {readFileSync} from "node:fs";
const sql=readFileSync(new URL("../supabase/migrations/202611180035_shopify_pixel_delivery_context_v2.sql",import.meta.url),"utf8");
test("pixel delivery context is exact-opportunity, service-only and reuses the eligibility gate",()=>{
 assert.match(sql,/resolve_shopify_pixel_delivery_context_v2/);
 assert.match(sql,/assess_shopify_pixel_delivery_eligibility_v2\(p_opportunity_id\)/);
 assert.match(sql,/request\.jwt\.claim\.role[\s\S]*?service_role_required/);
 assert.match(sql,/GRANT EXECUTE ON FUNCTION henvalt\.resolve_shopify_pixel_delivery_context_v2\(uuid\)[\s\S]*?TO service_role/);
});
test("resolver decrypts only trusted server credentials and exact-store customer identity",()=>{
 assert.match(sql,/vault\.decrypted_secrets/);
 assert.match(sql,/shopify_connections sc[\s\S]*?sc\.id=o\.shopify_connection_id/);
 assert.match(sql,/sp\.shopify_connection_id=o\.shopify_connection_id/);
 assert.match(sql,/pr\.recipient_fingerprint_secret_ref/);
 assert.match(sql,/pr\.api_token_secret_ref/);
 assert.match(sql,/gid:\/\/shopify\/Customer/);
 assert.doesNotMatch(sql,/customer_email|email_address|recipient_email\\s+(text|varchar)/i);
});
test("resolver is metadata-only and cannot authorize or submit delivery",()=>{
 assert.match(sql,/recipient_email_returned',false/);
 assert.match(sql,/permit_issued',false/);
 assert.match(sql,/send_attempt_created',false/);
 assert.match(sql,/provider_cost_reserved',false/);
 assert.match(sql,/provider_submission_performed',false/);
 assert.doesNotMatch(sql,/INSERT INTO henvalt\.shopify_pixel_delivery_permits_v2/);
 assert.doesNotMatch(sql,/INSERT INTO henvalt\.shopify_pixel_send_attempts_v2/);
});

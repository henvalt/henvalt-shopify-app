import test from "node:test";
import assert from "node:assert/strict";
import {readFileSync} from "node:fs";
const migration=readFileSync("supabase/migrations/202611170007_shopify_contact_resolution_and_delivery_v2.sql","utf8");
const edge=readFileSync("supabase/functions/henvalt-shopify-contact-delivery-v2/index.ts","utf8");
const reservationMigration=readFileSync("supabase/migrations/202611170008_shopify_delivery_cost_reservations_v2.sql","utf8");
test("context resolver is exact-store and server-role only",()=>{for(const x of ["shopify_connection_id","external_customer_reference","read_customers","vault.decrypted_secrets","access_token_secret_ref","api_token_secret_ref","recipient_fingerprint_secret_ref","shopify_app_registry","shopify_customer_email_consent_v2","shopify_delivery_suppressions_v2","shopify_order_identity_v2"])assert.ok(migration.includes(x),x);assert.match(migration,/REVOKE ALL ON FUNCTION henvalt.resolve_shopify_delivery_context_v2\(uuid\)[\s\S]*?FROM PUBLIC,anon,authenticated/);assert.match(migration,/GRANT EXECUTE ON FUNCTION henvalt.resolve_shopify_delivery_context_v2\(uuid\)[\s\S]*?TO service_role/);});
test("missing Shopify customer scope or jurisdiction fails closed",()=>{assert.match(migration,/coalesce\(\x27read_customers\x27=ANY\(v_row\.scopes\),false\) IS NOT TRUE/);assert.match(migration,/jurisdiction_country_code IS NULL/);});
test("email is resolved by exact Shopify customer ID and is not stored or returned",()=>{assert.match(edge,/customer\(id: \$id\) \{ id email \}/);assert.match(edge,/external_customer_reference/);assert.match(edge,/recipient_email_returned:false/);assert.doesNotMatch(migration,/customer_email\s+(text|varchar)/i);});
test("keyed fingerprint, permit checks and provider submission happen in trusted order",()=>{assert.match(edge,/crypto\.subtle\.importKey\("raw".*HMAC/s);assert.ok(edge.indexOf("issue_shopify_delivery_permit_v2")<edge.indexOf("consume_shopify_delivery_permit_v2"));assert.ok(edge.indexOf("consume_shopify_delivery_permit_v2")<edge.indexOf("api.mailersend.com/v1/email"));assert.match(edge,/to:\[\{email\}\]/);});
test("refresh uses existing serialized token lease and records outcomes",()=>{for(const x of ["claim_shopify_token_refresh","complete_shopify_token_refresh","fail_shopify_token_refresh",'grant_type:"refresh_token"'])assert.ok(edge.includes(x),x);assert.doesNotMatch(edge,/console\.(log|error)\([^\n]*(access|refresh)Token/i);});
test("migration 019 replaces the historical delivery gate only after atomic reservation exists",()=>{assert.match(migration,/MONETARY_USAGE_RESERVATION_REQUIRED/);assert.match(reservationMigration,/CREATE OR REPLACE FUNCTION henvalt\.resolve_shopify_delivery_context_v2/);assert.doesNotMatch(reservationMigration,/MONETARY_USAGE_RESERVATION_REQUIRED/);assert.match(reservationMigration,/CREATE TRIGGER shopify_delivery_cost_reserve_after_attempt_v2/);});
test("ambiguous provider submission is never blindly retried",()=>{assert.match(migration,/record_shopify_delivery_submission_v2/);assert.match(edge,/record\(attempt,"AMBIGUOUS"\)/);assert.match(edge,/record\(attempt,"SUBMITTED",messageId\)/);assert.match(edge,/record\(attempt,"FAILED"\)/);});

test("no-send interlock rejects missing MailerSend event readiness before any delivery lookup or provider request",()=>{
 const handler=edge.slice(edge.indexOf("Deno.serve("));
 const auth=handler.indexOf('if(!bearer||!eq(bearer,DELIVERY_AUTH_TOKEN))');
 const readiness=handler.indexOf('if(!MAILERSEND_V2_EVENTS_READY)');
 const parse=handler.indexOf('readJsonObject(req');
 const context=handler.indexOf('resolve_shopify_recovery_message_context_v2');
 const provider=handler.indexOf('https://api.mailersend.com/v1/email');
 assert.match(edge,/HENVALT_V2_MAILERSEND_EVENTS_READY/);
 assert.ok(auth>=0&&readiness>auth&&parse>readiness&&context>parse&&provider>context);
 assert.match(handler,/if\(!MAILERSEND_V2_EVENTS_READY\)return json\(503/);
});

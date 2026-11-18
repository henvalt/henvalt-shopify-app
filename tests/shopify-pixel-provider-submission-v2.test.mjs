import test from "node:test";
import assert from "node:assert/strict";
import {readFileSync} from "node:fs";
const edge=readFileSync(new URL("../supabase/functions/henvalt-shopify-pixel-delivery-v2/index.ts",import.meta.url),"utf8");
const sql=readFileSync(new URL("../supabase/migrations/202611180036_shopify_pixel_provider_submission_gate_v2.sql",import.meta.url),"utf8");
test("pixel worker is private, exact-opportunity scoped and does not accept caller-supplied recipient data",()=>{
 assert.match(edge,/HENVALT_PIXEL_DELIVERY_AUTH_TOKEN/);
 assert.match(edge,/content-length/);
 assert.match(edge,/Array\.isArray\(parsed\)/);
 assert.match(edge,/request_body_too_large/);
 assert.match(edge,/resolve_shopify_pixel_delivery_context_v2/);
 assert.match(edge,/opportunity_id/);
 assert.doesNotMatch(edge,/input\.(to|email|recipient_email|customer_gid)/i);
});
test("worker performs live Shopify consent lookups before permit and again after permit consumption",()=>{
 const first=edge.indexOf("const first=await lookupCustomer");
 const issue=edge.indexOf("issue_shopify_pixel_delivery_permit_v2");
 const consume=edge.indexOf("consume_shopify_pixel_delivery_permit_v2");
 const second=edge.indexOf("finalCustomer=await lookupCustomer");
 const send=edge.indexOf("api.mailersend.com/v1/email");
 assert.ok(first>=0&&first<issue&&issue<consume&&consume<second&&second<send);
 assert.match(edge,/emailMarketingConsent \{ marketingState consentUpdatedAt \}/);
 assert.match(edge,/finalCustomer\.state!=="SUBSCRIBED"/);
});
test("recipient PII is transient and only a keyed fingerprint enters authorization",()=>{
 assert.match(edge,/crypto\.subtle\.importKey\("raw".*HMAC/s);
 assert.match(edge,/p_recipient_fingerprint_hex:firstFingerprint/);
 assert.match(edge,/p_recipient_fingerprint_hex:finalFingerprint/);
 assert.match(edge,/recipient_email_returned:false/);
 assert.doesNotMatch(sql,/recipient_email\s+(text|varchar)/i);
 assert.doesNotMatch(edge,/console\.(log|error).*email/i);
});
test("provider submission follows a final database gate and is reconciled without blind retry",()=>{
 assert.ok(edge.indexOf("authorize_shopify_pixel_provider_submission_v2")<edge.indexOf("api.mailersend.com/v1/email"));
 assert.match(edge,/recordAttempt\(attemptId,"AMBIGUOUS"\)/);
 assert.match(edge,/recordAttempt\(attemptId,"SUBMITTED",messageRef\)/);
 assert.match(edge,/recordAttempt\(attemptId,"FAILED"\)/);
 assert.match(edge,/status:"ambiguous_provider_submission"/);
 assert.match(edge,/providerResponse\.status>=500\|\|providerResponse\.status===408/);
});
test("final gate is service-only, locks the attempt/reservation and rechecks consent eligibility and suppression",()=>{
 assert.match(sql,/request\.jwt\.claim\.role[\s\S]*?service_role_required/);
 assert.match(sql,/FOR UPDATE OF attempt_row,permit_row,reservation_row/);
 assert.match(sql,/reservation_status<>'RESERVED'/);
 assert.match(sql,/assess_shopify_pixel_delivery_eligibility_v2\(v_attempt\.opportunity_id\)/);
 assert.match(sql,/shopify_delivery_suppressions_v2/);
 assert.match(sql,/recipient_fingerprint/);
 assert.match(sql,/GRANT EXECUTE ON FUNCTION henvalt\.authorize_shopify_pixel_provider_submission_v2\(uuid,text\)[\s\S]*?TO service_role/);
});

test("worker preserves AMBIGUOUS cost state when a post-request ledger or response failure occurs",()=>{
 const requestStart=edge.indexOf('providerSubmissionStarted=true;');
 const providerFetch=edge.indexOf('fetch("https://api.mailersend.com/v1/email"');
 const outerCatch=edge.lastIndexOf('providerSubmissionStarted?"AMBIGUOUS":"FAILED"');
 assert.ok(requestStart>=0&&requestStart<providerFetch,"mark provider boundary before issuing HTTP request");
 assert.ok(outerCatch>providerFetch,"post-submission failures must reconcile as ambiguous, not release cost");
 assert.match(edge,/provider_outcome_requires_reconciliation/);
});

test("worker enforces the body limit while streaming even when Content-Length is absent",()=>{
 assert.match(edge,/async function parseJsonLimited\(request:Request,maxBytes:number\)/);
 assert.match(edge,/request\.body\?\.getReader\(\)/);
 assert.match(edge,/total>maxBytes/);
 assert.match(edge,/reader\.cancel\(\)/);
 assert.match(edge,/parseJsonLimited\(req,160000\)/);
});

import test from "node:test";
import assert from "node:assert/strict";
import {readFileSync} from "node:fs";

const sql=readFileSync(new URL("../supabase/migrations/202611180042_shopify_recovery_work_claims_v2.sql",import.meta.url),"utf8");
const materializer=readFileSync(new URL("../supabase/migrations/202611180043_shopify_checkout_intervention_materializer_v2.sql",import.meta.url),"utf8");
const integration=readFileSync(new URL("./sql/shopify-pixel-attempt-outcome-lifecycle-v2.test.sql",import.meta.url),"utf8");
const concurrency=readFileSync(new URL("./sql/shopify-recovery-work-claims-concurrency-v2.test.sh",import.meta.url),"utf8");

test("V2 recovery claims cover both independent checkout and pixel work shapes",()=>{
 assert.match(sql,/'CHECKOUT_INTERVENTION'/);
 assert.match(sql,/'PIXEL_OPPORTUNITY'/);
 assert.match(sql,/i\.status='READY_FOR_AUTHORIZATION'/);
 assert.match(sql,/o\.status='REVIEW_REQUIRED'/);
 assert.match(sql,/c\.status='PROMOTED'/);
 assert.match(sql,/NOT EXISTS \([\s\S]*?shopify_recovery_send_attempt_v2/);
 assert.match(sql,/NOT EXISTS \([\s\S]*?shopify_pixel_send_attempts_v2/);
 assert.match(sql,/NOT EXISTS \([\s\S]*?shopify_order_identity_v2/);
});

test("claims are service-only, exact-store, bounded and safe under concurrent workers",()=>{
 assert.match(sql,/request\.jwt\.claim\.role[\s\S]*?service_role_required/);
 assert.match(sql,/FOREIGN KEY\(shopify_connection_id,tenant_id\)/);
 assert.match(sql,/UNIQUE\(work_type,work_id\)/);
 assert.match(sql,/ON CONFLICT\(work_type,work_id\) DO UPDATE/);
 assert.match(sql,/lease_expires_at<=now\(\)/);
 assert.match(sql,/next_attempt_at<=now\(\)/);
 assert.match(sql,/attempt_count=henvalt\.shopify_recovery_work_claims_v2\.attempt_count\+1/);
 assert.match(sql,/GRANT EXECUTE ON FUNCTION henvalt\.claim_shopify_recovery_work_v2\(text,integer,integer\)[\s\S]*?TO service_role/);
});

test("lease completion rejects stale workers and supports bounded deferral",()=>{
 assert.match(sql,/p_outcome IS NULL OR p_outcome NOT IN \('HANDOFF_ACCEPTED','TERMINAL','DEFERRED'\)/);
 assert.match(sql,/lease_expires_at>now\(\)/);
 assert.match(sql,/SET lease_expires_at=now\(\),next_attempt_at=now\(\)\+p_retry_after/);
 assert.match(sql,/p_retry_after>interval '24 hours'/);
 assert.match(sql,/REVOKE ALL ON FUNCTION henvalt\.finish_shopify_recovery_work_claim_v2/);
 assert.match(integration,/Deferred work was not reclaimed with a fresh lease identity/);
 assert.match(integration,/Stale worker was able to complete a reclaimed lease/);
 assert.match(integration,/Completed pixel work was claimed again/);
});

test("work claims never carry recipient data or perform provider sends",()=>{
 assert.match(sql,/'recipient_pii_returned',false/);
 assert.match(sql,/'provider_called',false/);
 assert.match(sql,/'delivery_authorized',false/);
 assert.doesNotMatch(sql,/recipient_email|mailer_send_api_token|access_token|html_body|text_body/);
 assert.match(sql,/'lease_id',v_claim_id[\\s\\S]*?'work_type',v_work\.work_type[\\s\\S]*?'work_id',v_work\.work_id/);
 assert.doesNotMatch(sql,/'tenant_id',v_work\.tenant_id|'shopify_connection_id',v_work\.shopify_connection_id|'opportunity_id',v_work\.opportunity_id|'intervention_id',v_work\.intervention_id/);
});

test("parallel workers race against one durable work item and exactly one lease wins",()=>{
 assert.match(concurrency,/claim-race-worker-a/);
 assert.match(concurrency,/claim-race-worker-b/);
 assert.match(concurrency,/count\(DISTINCT c\.worker_id\)/);
 assert.match(concurrency,/"1:1:1"/);
 assert.match(concurrency,/shopify_recovery_work_claims_v2/);
});

test("checkout interventions are materialized from exact-store eligible opportunities without authorizing delivery",()=>{
 assert.match(materializer,/o\.status='CONTACT_RESOLUTION_PENDING'/);
 assert.match(materializer,/c\.state='READY_FOR_CONTACT_RESOLUTION'/);
 assert.match(materializer,/ch\.checkout_status='OPEN'/);
 assert.match(materializer,/ch\.shopify_checkout_token=c\.checkout_token/);
 assert.match(materializer,/FOR UPDATE OF o,c,ch SKIP LOCKED/);
 assert.match(materializer,/ON CONFLICT\(opportunity_id,step_number\) DO NOTHING/);
 assert.match(materializer,/'delivery_authorized',false/);
 assert.match(materializer,/'provider_called',false/);
 assert.match(materializer,/GRANT EXECUTE ON FUNCTION henvalt\.materialize_shopify_checkout_interventions_v2\(integer\)[\s\S]*?TO service_role/);
 assert.match(integration,/Checkout intervention materializer did not create the exact-store row/);
});

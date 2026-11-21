import test from "node:test";
import assert from "node:assert/strict";
import {readFileSync} from "node:fs";
const sql=readFileSync(new URL("../supabase/migrations/202611180037_shopify_pixel_attempt_outcome_reconciliation_v2.sql",import.meta.url),"utf8");
test("pixel SUBMITTED requires a provider message reference and other states cannot carry one",()=>{
 assert.match(sql,/p_status='SUBMITTED'[\s\S]*?p_provider_message_reference IS NULL/);
 assert.match(sql,/p_status<>'SUBMITTED' AND p_provider_message_reference IS NOT NULL/);
 assert.match(sql,/length\(p_provider_message_reference\)>240/);
});
test("outcome recording is service-only and preserves monotonic ambiguous reconciliation",()=>{
 assert.match(sql,/request\.jwt\.claim\.role[\s\S]*?service_role_required/);
 assert.match(sql,/v_attempt\.status NOT IN \('AUTHORIZED','AMBIGUOUS'\)/);
 assert.match(sql,/v_attempt\.status='AMBIGUOUS' AND p_status<>'SUBMITTED'/);
 assert.match(sql,/ELSE 'RESERVED'/);
 assert.match(sql,/GRANT EXECUTE ON FUNCTION henvalt\.record_shopify_pixel_send_attempt_result_v2\(uuid,text,text\)[\s\S]*?TO service_role/);
});

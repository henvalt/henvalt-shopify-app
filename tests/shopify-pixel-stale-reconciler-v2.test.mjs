import test from "node:test";
import assert from "node:assert/strict";
import {readFileSync} from "node:fs";
const sql=readFileSync(new URL("../supabase/migrations/202611180038_shopify_pixel_stale_attempt_reconciler_v2.sql",import.meta.url),"utf8");
test("stale authorized pixel attempts become ambiguous, never failed or resent",()=>{
 assert.match(sql,/status='AUTHORIZED'/);
 assert.match(sql,/SET status='AMBIGUOUS'/);
 assert.doesNotMatch(sql,/SET status='FAILED'/);
 assert.match(sql,/FOR UPDATE SKIP LOCKED/);
 assert.match(sql,/created_at<=p_before/);
});
test("stale attempt reconciliation is bounded, service-only and retains cost reservation",()=>{
 assert.match(sql,/request\.jwt\.claim\.role[\s\S]*?service_role_required/);
 assert.match(sql,/p_limit<1 OR p_limit>500/);
 assert.match(sql,/p_before>pg_catalog\.now\(\)-interval '2 minutes'/);
 assert.match(sql,/provider_cost_reservation_released',false/);
 assert.match(sql,/automatic_retry_performed',false/);
 assert.match(sql,/GRANT EXECUTE ON FUNCTION henvalt\.mark_stale_shopify_pixel_send_attempts_ambiguous_v2\(timestamptz,integer\)[\s\S]*?TO service_role/);
});

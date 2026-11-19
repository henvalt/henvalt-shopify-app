import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const read=(path)=>readFileSync(new URL(path,import.meta.url),"utf8");
const outcome=read("../supabase/migrations/202611190006_shopify_checkout_ambiguous_provider_reconciliation_v2.sql");
const edge=read("../supabase/functions/henvalt-shopify-contact-delivery-v2/index.ts");
const webhook=read("../supabase/migrations/202611170005_shopify_mailer_provider_events_suppression_v2.sql");
const workflow=read("../.github/workflows/shopify-identity-v2-validation.yml");
const sql=read("./sql/shopify-checkout-ambiguous-provider-reconciliation-v2.test.sql");
const mailerIntegration=read("./sql/shopify-mailer-provider-events-suppression-v2.test.sql");

test("checkout ambiguous result retains the provider message ID without releasing reserved cost",()=>{
  assert.match(outcome,/WHEN p_outcome='AMBIGUOUS' THEN coalesce\(v_attempt\.provider_message_id,p_provider_message_id\)/);
  assert.match(outcome,/WHEN p_outcome='SUBMITTED' THEN 'SETTLED'[\s\S]*?WHEN p_outcome='FAILED' THEN 'RELEASED'[\s\S]*?ELSE 'RESERVED'/);
  assert.match(edge,/record\(attempt,"AMBIGUOUS",messageId\)/);
  assert.match(edge,/record\(attempt,"AMBIGUOUS",providerMessageId\|\|undefined\)/);
});

test("AMBIGUOUS can reconcile to SUBMITTED but can never be downgraded to FAILED or change provider identity",()=>{
  assert.match(outcome,/IF v_attempt\.status='AMBIGUOUS' THEN[\s\S]*?p_outcome NOT IN \('SUBMITTED','AMBIGUOUS'\)/);
  assert.match(outcome,/v_attempt\.provider_message_id IS DISTINCT FROM p_provider_message_id/);
  assert.match(outcome,/p_outcome='FAILED' AND p_provider_message_id IS NOT NULL/);
});

test("signed activity.sent event settles ambiguous checkout attempts whether matched immediately or by reconciliation",()=>{
  assert.match(outcome,/NEW\.event_type='activity\.sent'[\s\S]*?status='SUBMITTED'[\s\S]*?status='AMBIGUOUS'/);
  assert.match(outcome,/reconcile_unmatched_shopify_checkout_provider_events_v2/);
  assert.match(outcome,/e\.processing_status='UNMATCHED'[\s\S]*?e\.provider_message_id IS NOT NULL/);
  assert.match(outcome,/JOIN henvalt\.shopify_recovery_send_attempt_v2 matched_attempt[\s\S]*?matched_attempt\.provider_message_id=e\.provider_message_id[\s\S]*?LIMIT p_limit/);
  assert.match(outcome,/ORDER BY e\.created_at,e\.id[\s\S]*?LIMIT p_limit[\s\S]*?FROM henvalt\.shopify_recovery_send_attempt_v2 a[\s\S]*?FOR UPDATE[\s\S]*?FROM henvalt\.shopify_mailer_provider_events_v2 e[\s\S]*?FOR UPDATE/);
});

test("late provider suppression events reconcile from the original attempt fingerprint",()=>{
  for(const type of ["activity.hard_bounced","activity.unsubscribed","activity.spam_complaint"]) assert.ok(outcome.includes(type));
  assert.match(outcome,/permit_row\.recipient_fingerprint/);
  assert.match(outcome,/Do not mark a suppression event processed without the original recipient fingerprint/);
  assert.match(outcome,/octet_length\(permit_row\.recipient_fingerprint\)=32/);
  assert.match(outcome,/SET status='DELIVERED'[\s\S]*?AND status IN \('SUBMITTED','AMBIGUOUS'\)/);
  assert.match(outcome,/ON CONFLICT\(shopify_connection_id,customer_identity_id,suppression_type,source_provider_event_id\)/);
  assert.match(outcome,/SELECT e\.id,e\.provider_event_id,e\.provider_account_key/);
  assert.match(outcome,/v_attempt\.id,v_event\.provider_event_id/);
});

test("checkout provider reconciliation is service-role-only and does not retry or resend",()=>{
  assert.match(outcome,/GRANT EXECUTE ON FUNCTION henvalt\.reconcile_unmatched_shopify_checkout_provider_events_v2\(integer\)[\s\S]*?TO service_role/);
  assert.match(outcome,/automatic_resend_performed',false/);
  assert.match(outcome,/ambiguous_cost_reservation_released',false/);
  assert.match(outcome,/mark_stale_shopify_checkout_send_attempts_ambiguous_v2/);
  assert.match(outcome,/automatic_retry_performed',false/);
  assert.match(sql,/has_function_privilege\('anon'/);
  assert.match(mailerIntegration,/record_shopify_delivery_submission_v2[\s\S]*?'AMBIGUOUS','provider-message-late-002'/);
  assert.match(mailerIntegration,/reconcile_unmatched_shopify_checkout_provider_events_v2\(10\)/);
  assert.match(mailerIntegration,/mark_stale_shopify_checkout_send_attempts_ambiguous_v2/);
  assert.match(mailerIntegration,/provider-event-unmatched-unsubscribe-004/);
  assert.match(mailerIntegration,/source_provider_event_id='provider-event-unmatched-unsubscribe-004'/);
  assert.match(mailerIntegration,/recipient_fingerprint=decode\(repeat\('ab',32\),'hex'\)/);
  assert.match(mailerIntegration,/provider_cost_reservation_released.*false/);
  assert.match(workflow,/202611190006_shopify_checkout_ambiguous_provider_reconciliation_v2\.sql/);
});

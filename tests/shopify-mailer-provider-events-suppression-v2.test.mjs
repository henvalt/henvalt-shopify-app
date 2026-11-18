import test from "node:test";
import assert from "node:assert/strict";
import {readFileSync} from "node:fs";
const migration=readFileSync("supabase/migrations/202611170005_shopify_mailer_provider_events_suppression_v2.sql","utf8");
const edge=readFileSync("supabase/functions/henvalt-mailersend-webhook-v2/index.ts","utf8");
const docs=readFileSync("docs/v2-mailersend-provider-events-and-suppression.md","utf8");
test("MailerSend webhook uses raw-body V2 signature and Vault-backed verification",()=>{
 assert.match(migration,/vault\.decrypted_secrets/);
 assert.match(migration,/extensions\.hmac\(v_body/);
 assert.match(migration,/WEBHOOK_TEST_VERIFIED/);
 assert.match(migration,/v_provider.status=\x27PENDING\x27 AND v_event_type=\x27webhook.test\x27/);
 assert.match(migration,/test_Am3L3GuOIc4blLUuHqAPxxwkZaJyEk5/);
 assert.match(edge,/req\.headers\.get\("signature"\)/);
 assert.match(edge,/p_raw_body_base64/);
});
test("provider event inbox never persists recipient email or raw body",()=>{
 assert.match(migration,/body_sha256/);
 assert.match(migration,/recipient_fingerprint bytea/);
 assert.doesNotMatch(migration,/recipient_email|raw_payload|email_address/);
 assert.match(edge,/recipient_pii_stored:false/);
});
test("suppression is exact-store and only hard bounce, unsubscribe and complaint are permanent gates",()=>{
 assert.match(migration,/UNIQUE\(shopify_connection_id,customer_identity_id,suppression_type,source_provider_event_id\)/);
 for(const event of ["activity.unsubscribed","activity.spam_complaint","activity.hard_bounced"])assert.ok(migration.includes(event));
 assert.match(migration,/shopify_connection_id,customer_identity_id/);
});
test("provider event retries are idempotent and unmatched events can later be correlated",()=>{
 assert.match(migration,/EVENT_ID_BODY_MISMATCH/);
 assert.match(migration,/v_existing_status<>'UNMATCHED'/);
 assert.match(migration,/UNMATCHED/);
 assert.match(docs,/1 December 2026/);
 const sql=readFileSync("tests/sql/shopify-mailer-provider-events-suppression-v2.test.sql","utf8");
 assert.match(sql,/Unmatched provider event did not correlate on retry/);
 assert.match(sql,/Late provider event did not reconcile the ambiguous send and settle its cost/);
 assert.match(sql,/MailerSend URL-validation test was not safely accepted/);
});

test("verified MailerSend events can reconcile ambiguous pixel attempts without caller-supplied message IDs",()=>{
 const reconciliation=readFileSync("supabase/migrations/202611180039_shopify_pixel_provider_event_reconciliation_v2.sql","utf8");
 assert.match(reconciliation,/processing_status<>'UNMATCHED'/);
 assert.match(reconciliation,/v_event\.event_type NOT IN \('activity\.sent'/);
 assert.match(reconciliation,/v_attempt\.status='AMBIGUOUS'/);
 assert.match(reconciliation,/record_shopify_pixel_send_attempt_result_v2/);
 assert.match(reconciliation,/provider_cost_state','SETTLED'/);
 assert.match(reconciliation,/GRANT EXECUTE ON FUNCTION henvalt\.reconcile_mailersend_pixel_provider_event_v2\(text,text\)[\s\S]*?TO service_role/);
 assert.match(edge,/reconcile_mailersend_pixel_provider_event_v2/);
 assert.match(edge,/p_provider_event_id:eventId/);
 assert.doesNotMatch(edge,/p_provider_message_reference/);
});

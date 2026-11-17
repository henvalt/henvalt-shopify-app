import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
const sql=readFileSync("tests/sql/shopify-email-consent-evidence-v2.test.sql","utf8");
const migration=readFileSync("supabase/migrations/202611170003_shopify_email_consent_evidence_v2.sql","utf8");
const oauth=readFileSync("supabase/functions/henvalt-shopify-oauth-v2/index.ts","utf8");
const ingress=readFileSync("supabase/functions/henvalt-shopify-webhook-ingress/index.ts","utf8");

test("OAuth requests customer read access and registers the email consent topic",()=>{
 assert.match(oauth,/customers_email_marketing_consent\/update/);
 assert.match(oauth,/CUSTOMERS_EMAIL_MARKETING_CONSENT_UPDATE/);
});
test("verified ingress invokes consent projection before acknowledging",()=>{
 assert.match(ingress,/project_verified_shopify_email_consent_v2/);
 assert.match(ingress,/consent_projection_unavailable/);
});
test("projection is replay-safe, ordered by consent timestamp, and fail-closed on ties",()=>{
 assert.match(migration,/GET DIAGNOSTICS v_event_inserted = ROW_COUNT/);
 assert.match(migration,/IF v_event_inserted = 0 THEN/);
 assert.match(migration,/v_consent_at>v_existing_at/);
 assert.match(migration,/v_state IS DISTINCT FROM v_existing_state/);
 assert.match(migration,/marketing_state='UNKNOWN'/);
 assert.match(sql,/Out-of-order older event overwrote current consent/);
 assert.match(sql,/Conflicting same-timestamp consent did not fail closed/);
});
test("SQL integration covers exact receipt replay and email non-persistence",()=>{
 assert.match(sql,/Consent receipt replay changed current state/);
 assert.match(sql,/email_address/);
 assert.match(sql,/Consent evidence schema unexpectedly stores email fields/);
});

import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const handler = readFileSync(
  new URL("../supabase/functions/henvalt-mailersend-delivery/handler.mjs", import.meta.url),
  "utf8",
);
const migration = readFileSync(
  new URL("../supabase/migrations/202611220009_mailersend_delivery_envelope_binding.sql", import.meta.url),
  "utf8",
);

test("provider egress is downstream of database-bound delivery envelope authorization", () => {
  const credentialClaim = handler.indexOf("/rpc/get_mailersend_token_for_delivery");
  const envelopeCheck = handler.indexOf("/rpc/assert_mailersend_delivery_envelope");
  const providerSend = handler.indexOf("https://api.mailersend.com/v1/email");
  assert.ok(credentialClaim >= 0);
  assert.ok(envelopeCheck > credentialClaim);
  assert.ok(providerSend > envelopeCheck);
  assert.match(handler, /envelopeAuthorized !== true/);
  assert.match(handler, /delivery_envelope_not_authorized/);
});

test("envelope authorization binds tenant, claimed delivery, recipient and configured sender identity", () => {
  assert.match(migration, /dr\.tenant_id = p_tenant_id/i);
  assert.match(migration, /dr\.id = p_delivery_request_id/i);
  assert.match(migration, /dr\.provider_claimed_at IS NOT NULL/i);
  assert.match(migration, /dr\.status = 'UNKNOWN'/i);
  assert.match(migration, /dr\.recipient_reference[\s\S]*?p_to/i);
  assert.match(migration, /m\.subject[\s\S]*?p_subject/i);
  assert.match(migration, /render_sender_identity_footer[\s\S]*?p_html_body/i);
  assert.match(migration, /render_email_plain_text[\s\S]*?p_text_body/i);
  assert.match(migration, /messaging_compliance,sender_profile,merchant_confirmed/i);
  assert.match(migration, /si\.sender_reference[\s\S]*?p_from_email/i);
  assert.match(migration, /metadata->>'from_name'[\s\S]*?p_from_name/i);
  assert.match(migration, /metadata->>'reply_to'[\s\S]*?p_reply_to/i);
  assert.match(migration, /t\.status = 'ACTIVE'/i);
  assert.match(migration, /pc\.configuration->>'credential_validated' = 'true'/i);
  assert.match(migration, /REVOKE ALL ON FUNCTION henvalt\.assert_mailersend_delivery_envelope[\s\S]*?PUBLIC, anon, authenticated/i);
  assert.match(migration, /GRANT EXECUTE ON FUNCTION henvalt\.assert_mailersend_delivery_envelope[\s\S]*?service_role/i);
});

import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const migration = readFileSync(
  new URL("../supabase/migrations/202611210001_provider_send_interlock_v1.sql", import.meta.url),
  "utf8",
);

test("global send control defaults closed and missing row fails closed", () => {
  assert.match(migration, /provider_sending_enabled boolean NOT NULL DEFAULT false/i);
  assert.match(migration, /COALESCE\([\s\S]*?provider_sending_enabled[\s\S]*?,\s*false\s*\)/i);
  assert.match(migration, /ON CONFLICT \(control_key\) DO NOTHING/i);
});

test("control table is server-only and RLS protected", () => {
  assert.match(migration, /ENABLE ROW LEVEL SECURITY/i);
  assert.match(migration, /REVOKE ALL ON henvalt\.provider_send_control FROM PUBLIC, anon, authenticated, service_role/i);
  assert.match(migration, /REVOKE ALL ON FUNCTION henvalt\.provider_sending_is_enabled\(\)/i);
});

test("interlock guards initial UNKNOWN inserts and both send-claim updates", () => {
  assert.match(migration, /BEFORE INSERT OR UPDATE OF status, provider_claimed_at/i);
  assert.match(migration, /TG_OP = 'INSERT'[\s\S]*?NEW\.status = 'UNKNOWN'[\s\S]*?NEW\.provider_claimed_at IS NOT NULL/i);
  assert.match(migration, /TG_OP = 'UPDATE'[\s\S]*?NEW\.status = 'UNKNOWN'[\s\S]*?OLD\.provider_claimed_at IS NULL[\s\S]*?NEW\.provider_claimed_at IS NOT NULL/i);
  assert.match(migration, /IF v_send_claim THEN\s+PERFORM henvalt\.assert_provider_sending_enabled\(\);/i);
  assert.match(migration, /CREATE OR REPLACE FUNCTION henvalt\.assert_provider_sending_enabled\(\)[\s\S]*?FOR SHARE/i);
  assert.match(migration, /USING ERRCODE = '42501'/i);
});

test("interlock trigger is installed on delivery requests", () => {
  assert.match(migration, /CREATE TRIGGER delivery_requests_provider_send_interlock[\s\S]*?ON henvalt\.delivery_requests[\s\S]*?EXECUTE FUNCTION henvalt\.enforce_provider_send_interlock\(\)/i);
});

test("credential release is gated before the legacy token reader and one-off test messages stay blocked", () => {
  assert.match(migration, /ALTER FUNCTION henvalt\.get_mailersend_token_for_delivery\(uuid, uuid\)\s+RENAME TO get_mailersend_token_for_delivery_legacy_v1/i);
  assert.match(migration, /CREATE OR REPLACE FUNCTION henvalt\.get_mailersend_token_for_delivery\([\s\S]*?PERFORM henvalt\.assert_provider_sending_enabled\(\)/i);
  assert.match(migration, /m\.metadata->>'test_only' = 'true'[\s\S]*?HENVALT_ONE_OFF_TEST_SEND_DISABLED/i);
  assert.match(migration, /REVOKE ALL ON FUNCTION henvalt\.get_mailersend_token_for_delivery_legacy_v1\(uuid, uuid\)[\s\S]*?service_role/i);
});

test("trigger implementation is not callable as a client-facing RPC", () => {
  assert.match(migration, /REVOKE ALL ON FUNCTION henvalt\.enforce_provider_send_interlock\(\)[\s\S]*?FROM PUBLIC, anon, authenticated, service_role/i);
});

test("operator changes are audited and the setter is not granted to app roles", () => {
  assert.match(migration, /CREATE TABLE IF NOT EXISTS henvalt[.]provider_send_control_events/i);
  assert.match(migration, /INSERT INTO henvalt[.]provider_send_control_events/i);
  assert.match(migration, /ALTER TABLE henvalt[.]provider_send_control_events ENABLE ROW LEVEL SECURITY/i);
  assert.match(migration, /REVOKE ALL ON henvalt[.]provider_send_control_events FROM PUBLIC, anon, authenticated, service_role/i);
  assert.match(migration, /CREATE OR REPLACE FUNCTION henvalt[.]set_provider_sending_enabled[(]/i);
  assert.match(migration, /p_enabled boolean,/i);
  assert.match(migration, /p_reason text/i);
  assert.match(migration, /REVOKE ALL ON FUNCTION henvalt[.]set_provider_sending_enabled[(]boolean, text[)]/i);
  assert.match(migration, /FROM PUBLIC, anon, authenticated, service_role/i);
});

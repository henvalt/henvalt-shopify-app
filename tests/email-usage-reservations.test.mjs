import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const migration = readFileSync(
  new URL("../supabase/migrations/202611230001_email_usage_reservations.sql", import.meta.url),
  "utf8",
);

test("email quota is reserved in the same transaction as the delivery claim", () => {
  assert.match(migration, /OLD\.status = 'PENDING' AND NEW\.status = 'UNKNOWN'/);
  assert.match(migration, /FROM henvalt\.billing_accounts[\s\S]*?FOR UPDATE/);
  assert.match(migration, /email_usage_measurements[\s\S]*?email_usage_reservations/);
  assert.match(migration, /v_email_count \+ v_reserved_count >= v_account\.monthly_email_limit/);
  assert.match(migration, /INSERT INTO henvalt\.email_usage_reservations/);
  assert.match(migration, /delivery_request_id uuid NOT NULL UNIQUE/);
});

test("reservation settlement is conservative and never expires ambiguous sends", () => {
  assert.match(migration, /v_state IN \('ACCEPTED', 'DELIVERED', 'UNKNOWN'\)/);
  assert.match(migration, /NEW\.provider_status_code IN \(400, 401, 403, 404, 405, 410, 413, 415, 422\)/);
  assert.match(migration, /status IN \('RESERVED', 'RELEASED'\)/);
  assert.match(migration, /AND status = 'RESERVED'/);
  assert.doesNotMatch(migration, /DELETE FROM henvalt\.email_usage_reservations/i);
  assert.doesNotMatch(migration, /expires_at/i);
  assert.match(migration, /email_usage_reservation_events/);
  assert.match(migration, /event_type text NOT NULL CHECK/);
  assert.match(migration, /BEFORE UPDATE OR DELETE ON henvalt\.email_usage_reservation_events/i);
});

test("reservation and event data remain private to the database owner", () => {
  assert.match(migration, /ENABLE ROW LEVEL SECURITY/);
  assert.match(migration, /REVOKE ALL ON henvalt\.email_usage_reservations FROM PUBLIC, anon, authenticated, service_role/);
  assert.match(migration, /REVOKE ALL ON henvalt\.email_usage_reservation_events FROM PUBLIC, anon, authenticated, service_role/);
  assert.match(migration, /REVOKE ALL ON FUNCTION henvalt\.sync_email_usage_reservation_after_attempt\(\)[\s\S]*?FROM PUBLIC, anon, authenticated, service_role/);
});

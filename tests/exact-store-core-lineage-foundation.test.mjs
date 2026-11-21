import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const migration = readFileSync(
  new URL("../supabase/migrations/202611160007_exact_store_core_lineage_foundation.sql", import.meta.url),
  "utf8"
);

test("core identity migration adds nullable exact-store lineage without backfilling", () => {
  for (const table of ["customers", "sessions", "session_aliases", "checkouts", "canonical_events"]) {
    assert.match(migration, new RegExp(`ALTER TABLE henvalt\\.${table}[\\s\\S]*?ADD COLUMN IF NOT EXISTS shopify_connection_id uuid`));
    assert.match(migration, new RegExp(`COMMENT ON COLUMN henvalt\\.${table}\\.shopify_connection_id[\\s\\S]*?NULL means historical or unresolved`));
  }
  assert.doesNotMatch(migration, /UPDATE\s+henvalt\./i);
});

test("connection lineage is constrained to a real connection in the same tenant", () => {
  for (const name of [
    "customers_connection_tenant_fkey",
    "sessions_connection_tenant_fkey",
    "session_aliases_connection_tenant_fkey",
    "checkouts_connection_tenant_fkey",
    "canonical_events_connection_tenant_fkey"
  ]) assert.ok(migration.includes(name));
  assert.match(migration, /REFERENCES henvalt\.shopify_connections \(id, tenant_id\)/);
  assert.match(migration, /NOT VALID/);
});

test("customer and session relationships cannot cross a verified store boundary", () => {
  assert.match(migration, /sessions_customer_same_connection_fkey/);
  assert.match(migration, /checkouts_customer_same_connection_fkey/);
  assert.match(migration, /session_aliases_session_same_connection_fkey/);
  assert.match(migration, /FOREIGN KEY \(customer_id, tenant_id, shopify_connection_id\)/);
  assert.match(migration, /FOREIGN KEY \(tenant_id, shopify_connection_id, session_reference\)/);
});

test("legacy tenant-only unique keys are not dropped or replaced in this stage", () => {
  assert.doesNotMatch(migration, /DROP\s+CONSTRAINT/i);
  assert.doesNotMatch(migration, /DROP\s+INDEX/i);
  assert.match(migration, /Existing V1 ON CONFLICT contracts remain intact/);
  assert.match(migration, /CREATE UNIQUE INDEX IF NOT EXISTS customers_tenant_connection_shopify_id_uidx/);
  assert.match(migration, /CREATE UNIQUE INDEX IF NOT EXISTS checkouts_tenant_connection_shopify_id_uidx/);
});

test("canonical event idempotency can be qualified by connection for the later writer", () => {
  assert.match(migration, /canonical_events_tenant_connection_idempotency_uidx/);
  assert.match(migration, /shopify_connection_id, idempotency_key/);
});

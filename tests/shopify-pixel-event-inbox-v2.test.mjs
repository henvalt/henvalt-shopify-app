import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const migration = readFileSync(
  new URL("../supabase/migrations/202611160008_shopify_pixel_event_inbox_v2.sql", import.meta.url),
  "utf8"
);

test("pixel V2 derives tenant and connection only from the authorized pixel key", () => {
  assert.match(migration, /FROM henvalt\.pixel_keys pk[\s\S]*?JOIN henvalt\.shopify_connections sc[\s\S]*?sc\.id = pk\.shopify_connection_id[\s\S]*?sc\.tenant_id = pk\.tenant_id/);
  assert.match(migration, /pk\.active = true[\s\S]*?pk\.revoked_at IS NULL[\s\S]*?p_origin = ANY\(pk\.allowed_origins\)/);
  assert.match(migration, /The authoritative tenant and connection come only from the active/);
  assert.doesNotMatch(migration, /p_payload\s*->>\s*'shopify_connection_id'/i);
  assert.doesNotMatch(migration, /p_payload\s*->>\s*'tenant_id'/i);
});

test("pixel V2 writes to a connection-bound inbox and not legacy recovery tables", () => {
  assert.match(migration, /shopify_pixel_event_inbox_v2/);
  assert.match(migration, /UNIQUE \(shopify_connection_id, source_event_id\)/);
  assert.match(migration, /FOREIGN KEY \(shopify_connection_id, tenant_id\)[\s\S]*?REFERENCES henvalt\.shopify_connections \(id, tenant_id\)/);
  for (const table of ["canonical_events", "customers", "sessions", "session_aliases", "checkouts", "opportunities", "recovery_interventions", "delivery_requests"]) {
    assert.doesNotMatch(migration, new RegExp(`(?:INSERT\\s+INTO|UPDATE)\\s+henvalt\\.${table}\\b`, "i"));
  }
  assert.match(migration, /PENDING_ADAPTER/);
});

test("analytics consent gates all identity-bearing pixel fields", () => {
  assert.match(migration, /WHEN v_analytics_allowed[\s\S]*?customer_reference/);
  assert.match(migration, /CASE WHEN v_analytics_allowed THEN v_client_id ELSE NULL END/);
  assert.match(migration, /IF v_analytics_allowed THEN[\s\S]*?client_id[\s\S]*?customer_reference[\s\S]*?checkout_reference/);
  assert.match(migration, /Marketing consent is recorded separately and never implies/);
});

test("pixel V2 rejects changed-body reuse and preserves idempotent retries", () => {
  assert.match(migration, /ON CONFLICT \(shopify_connection_id, source_event_id\) DO NOTHING/);
  assert.match(migration, /EVENT_ID_BODY_MISMATCH/);
  assert.match(migration, /v_existing_digest IS DISTINCT FROM v_event_digest/);
});

test("pixel V2 remains server-only and does not alter the legacy writer", () => {
  assert.match(migration, /SECURITY DEFINER[\s\S]*?SET search_path = ''/);
  assert.match(migration, /REVOKE ALL ON FUNCTION henvalt\.ingest_pixel_event_v2[\s\S]*?FROM PUBLIC, anon, authenticated/);
  assert.match(migration, /GRANT EXECUTE ON FUNCTION henvalt\.ingest_pixel_event_v2[\s\S]*?TO service_role/);
  assert.doesNotMatch(migration, /CREATE OR REPLACE FUNCTION henvalt\.ingest_pixel_event\(/);
});

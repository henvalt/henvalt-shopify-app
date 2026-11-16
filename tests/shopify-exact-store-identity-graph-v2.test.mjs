import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const migration = readFileSync(
  new URL("../supabase/migrations/202611160009_shopify_pixel_identity_graph_v2.sql", import.meta.url),
  "utf8"
);
const docs = readFileSync(
  new URL("../docs/shopify-exact-store-identity-graph-v2.md", import.meta.url),
  "utf8"
);

test("V2 customer identity is exact-connection scoped and never email-keyed", () => {
  assert.match(migration, /shopify_customer_identity_v2/);
  assert.match(migration, /UNIQUE \(shopify_connection_id, external_customer_reference\)/);
  assert.doesNotMatch(migration, /email\s+text/i);
  assert.match(docs, /No email column or email-based identity fallback/);
});

test("sessions and aliases enforce same-connection identity", () => {
  assert.match(migration, /UNIQUE \(shopify_connection_id, session_reference\)/);
  assert.match(migration, /shopify_session_alias_identity_v2_connection_alias_uidx/);
  assert.match(migration, /session_alias_identity_v2_session_same_connection_fkey/);
  assert.match(migration, /SESSION_ALIAS_ALREADY_BOUND_TO_DIFFERENT_SESSION/);
});

test("checkout identity is connection-scoped and anchored to a verified receipt", () => {
  assert.match(migration, /UNIQUE \(shopify_connection_id, shopify_checkout_id\)/);
  assert.match(migration, /shopify_checkout_identity_v2_connection_token_uidx/);
  assert.match(migration, /shopify_checkout_identity_v2_verified_source_fkey/);
  assert.match(docs, /no checkout projection RPC is enabled yet/);
});

test("pixel projection derives identity only from its validated inbox row", () => {
  assert.match(migration, /project_shopify_pixel_identity_v2\(p_inbox_id uuid\)/);
  assert.match(migration, /FROM henvalt\.shopify_pixel_event_inbox_v2/);
  assert.match(migration, /analytics_processing_allowed IS NOT TRUE/);
  assert.match(migration, /SESSION_CUSTOMER_IDENTITY_CONFLICT/);
  assert.match(migration, /REVOKE ALL ON FUNCTION henvalt\.project_shopify_pixel_identity_v2/);
  assert.match(migration, /GRANT EXECUTE ON FUNCTION henvalt\.project_shopify_pixel_identity_v2\(uuid\)\s+TO service_role/);
});

test("legacy recovery and canonical consumers remain isolated", () => {
  assert.match(docs, /isolated from legacy customers, sessions, aliases, checkouts, canonical events, recovery, delivery, attribution and billing/);
  assert.match(docs, /No V1 function is replaced or altered/);
  assert.match(docs, /No tenant-only unique constraint is dropped/);
});

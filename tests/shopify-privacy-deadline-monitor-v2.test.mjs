import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const migration = readFileSync(new URL("../supabase/migrations/202611170023_shopify_privacy_deadline_monitor_v2.sql", import.meta.url), "utf8");

test("privacy monitor computes the Shopify 30-day deadline and highlights operational risk", () => {
  assert.match(migration, /received_at \+ interval '30 days'/);
  for (const status of ["COMPLETED", "RETRY_LIMIT_REACHED", "OVERDUE", "IDENTITY_REVIEW_REQUIRED", "QUEUE_MISSING", "PROCESSING_FAILED", "REVIEW_REQUIRED", "CLAIM_LEASE_EXPIRED", "DUE_WITHIN_7_DAYS", "DUE_WITHIN_14_DAYS", "ON_TRACK"]) {
    assert.ok(migration.includes("'" + status + "'"), "missing deadline status " + status);
  }
  assert.match(migration, /requires_attention/);
  assert.match(migration, /connection_binding_valid/);
  assert.match(migration, /customer_scope_complete/);
});

test("privacy monitor is read-only and service-role-only", () => {
  assert.match(migration, /CREATE OR REPLACE VIEW henvalt\.shopify_privacy_deadline_monitor_v2/);
  assert.match(migration, /REVOKE ALL ON henvalt\.shopify_privacy_deadline_monitor_v2[\s\S]*FROM PUBLIC, anon, authenticated, service_role/);
  assert.match(migration, /GRANT SELECT ON henvalt\.shopify_privacy_deadline_monitor_v2 TO service_role/);
  assert.doesNotMatch(migration, /\bINSERT\s+INTO\b|\bUPDATE\s+henvalt\.|\bDELETE\s+FROM\b/i);
});

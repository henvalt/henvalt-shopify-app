import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const migration = readFileSync(
  new URL("../supabase/migrations/202611180041_shopify_v2_dashboard_read_model.sql", import.meta.url),
  "utf8",
);
const sqlTest = readFileSync(
  new URL("./sql/shopify-v2-dashboard-read-model.test.sql", import.meta.url),
  "utf8",
);
const workflow = readFileSync(
  new URL("../.github/workflows/shopify-identity-v2-validation.yml", import.meta.url),
  "utf8",
);

test("dashboard V2 read-model integration test exercises seeded active and inactive stores", () => {
  assert.match(sqlTest, /control_plane_dashboard_summary_v2\(v_store_a/);
  assert.match(sqlTest, /control_plane_dashboard_summary_v2\(v_store_b/);
  assert.match(sqlTest, /Inactive Store B must not return dashboard metrics/);
  assert.match(sqlTest, /Dashboard summary RPC is not restricted to service_role/);
  assert.match(sqlTest, /jsonb_array_length\(v_series\)<>3/);
  assert.match(sqlTest, /2026-11-16/);
  assert.match(sqlTest, /2026-11-17/);
  assert.match(sqlTest, /2026-11-18/);
});

test("dashboard V2 seeded integration test is part of disposable PostgreSQL CI", () => {
  assert.match(workflow, /tests\/sql\/shopify-v2-dashboard-read-model\.test\.sql/);
  assert.match(workflow, /Apply candidate migrations 001 through 062[\s\S]*202611180041_shopify_v2_dashboard_read_model\.sql/);
});

test("dashboard V2 summary remains service-role-only and uses confirmed exact-store attribution", () => {
  assert.match(migration, /a\.shopify_connection_id=p_shopify_connection_id/);
  assert.match(migration, /a\.status='CONFIRMED'/);
  assert.match(migration, /a\.net_recovered_amount>0/);
  assert.match(migration, /REVOKE ALL ON FUNCTION henvalt\.control_plane_dashboard_summary_v2[\s\S]*FROM PUBLIC,anon,authenticated/);
  assert.match(migration, /GRANT EXECUTE ON FUNCTION henvalt\.control_plane_dashboard_summary_v2[\s\S]*TO service_role/);
});

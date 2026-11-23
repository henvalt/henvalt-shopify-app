import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const migration = readFileSync(
  new URL("../supabase/migrations/202611230002_dashboard_currency_attribution_integrity.sql", import.meta.url),
  "utf8",
);
const handler = readFileSync(
  new URL("../supabase/functions/henvalt-merchant-dashboard/index.ts", import.meta.url),
  "utf8",
);
const dashboard = readFileSync(new URL("../dashboard/index.html", import.meta.url), "utf8");

test("dashboard totals never add unlike currencies", () => {
  assert.match(migration, /count\(DISTINCT upper\(btrim\(rl\.currency::text\)\)\)/i);
  assert.match(migration, /IF v_currency_conflict THEN\s+v_revenue := NULL/i);
  assert.match(migration, /revenueByCurrency/);
  assert.match(migration, /current_currency_conflict/);
  assert.match(migration, /comparison_currency_conflict/);
  assert.match(migration, /v_invalid_currency_count > 0/);
  assert.match(migration, /ELSE 'UNKNOWN'/);
  assert.match(handler, /currencyConflict \? null/);
  assert.match(handler, /existing\.currency !== currency/);
  assert.match(dashboard, /Multiple currencies/);
  assert.match(dashboard, /money\(x\.amount,x\.currency\|\|currency\)/);
});

test("recovered order counts derive from confirmed attribution, not mutable opportunity status", () => {
  assert.match(migration, /count\(DISTINCT oa\.order_id\)/);
  assert.match(migration, /oa\.attribution_confidence = 'CONFIRMED'/);
  assert.match(migration, /event_type = 'unclassified'/);
  assert.match(migration, /Closed — attribution unconfirmed/);
  assert.match(migration, /THEN 'recovered'/);
});

test("dashboard RPC privileges remain service-role-only", () => {
  assert.match(migration, /REVOKE ALL ON FUNCTION henvalt\.control_plane_dashboard_summary[\s\S]*?FROM PUBLIC, anon, authenticated/);
  assert.match(migration, /GRANT EXECUTE ON FUNCTION henvalt\.control_plane_dashboard_summary[\s\S]*?TO service_role/);
  assert.match(migration, /REVOKE ALL ON FUNCTION henvalt\.control_plane_revenue_series[\s\S]*?FROM PUBLIC, anon, authenticated/);
  assert.match(migration, /GRANT EXECUTE ON FUNCTION henvalt\.control_plane_revenue_series[\s\S]*?TO service_role/);
});

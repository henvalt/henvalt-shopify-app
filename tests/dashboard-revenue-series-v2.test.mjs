import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const migration = readFileSync(
  new URL("../supabase/migrations/202611180041_shopify_v2_dashboard_read_model.sql", import.meta.url),
  "utf8",
);
const dashboard = readFileSync(new URL("../dashboard/index.html", import.meta.url), "utf8");

test("V2 dashboard revenue series is daily, UTC-bucketed and exact-connection scoped", () => {
  assert.match(migration, /v_revenue_series jsonb/);
  assert.match(migration, /generate_series\([\s\S]*date_trunc\('day',p_from AT TIME ZONE 'UTC'\)[\s\S]*date_trunc\('day',p_to AT TIME ZONE 'UTC'\)/);
  assert.match(migration, /a\.shopify_connection_id=p_shopify_connection_id/);
  assert.match(migration, /a\.status='CONFIRMED'/);
  assert.match(migration, /a\.net_recovered_amount>0/);
  assert.match(migration, /a\.attributed_at >= \(d\.day AT TIME ZONE 'UTC'\)/);
  assert.match(migration, /'revenueSeries',v_revenue_series/);
});

test("dashboard chart uses the server-aggregated revenue series, not individual activity rows", () => {
  assert.match(dashboard, /Array\.isArray\(data\.revenueSeries\)/);
  assert.match(dashboard, /revenueSeries\.map\(x=>Number\(x\.amount\)\|\|0\)/);
  assert.match(dashboard, /DAILY CONFIRMED REVENUE/);
  assert.doesNotMatch(dashboard, /a\.filter\(x=>x\.outcome==="recovered"&&x\.amount!=null\)/);
});

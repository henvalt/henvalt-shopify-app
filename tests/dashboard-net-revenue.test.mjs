import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const summary = readFileSync(new URL("../supabase/migrations/202611210003_dashboard_confirmed_revenue_metrics.sql", import.meta.url), "utf8");
const series = readFileSync(new URL("../supabase/migrations/202611220012_dashboard_net_revenue_series.sql", import.meta.url), "utf8");
const workflow = readFileSync(new URL("../.github/workflows/provider-send-interlock-static.yml", import.meta.url), "utf8");
const merchantDashboard = readFileSync(new URL("../supabase/functions/henvalt-merchant-dashboard/index.ts", import.meta.url), "utf8");
const dashboardHtml = readFileSync(new URL("../dashboard/index.html", import.meta.url), "utf8");
const acceptanceMatrix = readFileSync(new URL("../docs/v1-whole-system-staging-acceptance-matrix.md", import.meta.url), "utf8");

test("dashboard summary and activity amounts include confirmed refunds as negative revenue", () => {
  assert.match(summary, /entry_type IN \('RECOVERY', 'ADJUSTMENT'\)/);
  assert.match(summary, /rl\.order_id = oa\.order_id[\s\S]*?rl\.entry_type = 'ADJUSTMENT'[\s\S]*?sum\(rl\.amount\)/);
});

test("dashboard revenue series is net of confirmed refund and cancellation adjustments", () => {
  assert.equal((series.match(/entry_type IN \('RECOVERY', 'ADJUSTMENT'\)/g) || []).length, 3);
  assert.match(series, /SUM\(rl\.amount\)/);
  assert.match(series, /current_revenue/);
  assert.match(series, /previous_revenue/);
});

test("safety CI tracks the dashboard net-revenue migration", () => {
  assert.match(workflow, /202611220012_dashboard_net_revenue_series\.sql/);
  assert.match(workflow, /dashboard-net-revenue\.test\.mjs/);
  assert.match(workflow, /node --test[\s\S]*tests\/dashboard-net-revenue\.test\.mjs/);
});

test("net revenue chart retains negative adjustment amounts rather than dropping refunds", () => {
  assert.match(series, /entry_type IN \('RECOVERY', 'ADJUSTMENT'\)/);
  assert.doesNotMatch(series, /entry_type = 'RECOVERY' AND rl\.billable IS TRUE/);
});

test("merchant dashboard API supplies the series consumed by the chart", () => {
  assert.match(merchantDashboard, /rpc\/control_plane_revenue_series/);
  assert.match(merchantDashboard, /p_granularity: "day"/);
  assert.match(merchantDashboard, /revenueSeries,?[\s\S]*range:/);
  assert.match(workflow, /supabase\/functions\/henvalt-merchant-dashboard\/index\.ts/);
  assert.match(workflow, /Type-check merchant dashboard Edge Function/);
});

test("credentialed dashboard API requests reject unexpected redirects", () => {
  assert.equal((merchantDashboard.match(/redirect: "error"/g) || []).length, 4);
});

test("dashboard chart scales around zero so negative refund days stay visible", () => {
  assert.match(dashboardHtml, /Math\.min\(\.\.\.vals,0\)/);
  assert.match(dashboardHtml, /Math\.max\(\.\.\.vals,0\)/);
  assert.match(dashboardHtml, /zeroY/);
});

test("staging matrix explicitly gates refund-adjusted revenue and fee credits", () => {
  assert.match(acceptanceMatrix, /REV-05 \| Net recovered revenue/);
  assert.match(acceptanceMatrix, /BILL-04 \| Refund fee credit/);
});

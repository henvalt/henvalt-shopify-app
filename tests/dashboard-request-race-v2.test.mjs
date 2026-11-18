import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const dashboard = readFileSync("dashboard/index.html", "utf8");
const loadStart = dashboard.indexOf("async function load(){");
const loadEnd = dashboard.indexOf("async function init(){", loadStart);
const load = dashboard.slice(loadStart, loadEnd);
const ownerStateStart = dashboard.indexOf("async function ownerState()");
const ownerStateEnd = dashboard.indexOf('$("shopifyconnectform")', ownerStateStart);
const ownerState = dashboard.slice(ownerStateStart, ownerStateEnd);

test("dashboard requests abort superseded loads and ignore stale responses", () => {
  assert.match(dashboard, /dashboardRequestId=0/);
  assert.match(load, /if\(dashboardRequest\)dashboardRequest\.abort\(\)/);
  assert.match(load, /signal:controller\.signal/);
  assert.match(load, /if\(requestId!==dashboardRequestId\)return/);
  assert.match(load, /e\?\.name==="AbortError"/);
});
test("sign-out invalidates in-flight requests and clears merchant metrics", () => {
  assert.match(dashboard, /function cancelDashboardLoad\(\)/);
  assert.match(dashboard, /dashboardRequestId\+\+/);
  assert.match(ownerState, /cancelDashboardLoad\(\);clearDashboardData\(\)/);
  assert.match(dashboard, /function clearDashboardData\(\)/);
  assert.match(dashboard, /No merchant metrics are retained in this view after sign-out/);
});
test("dashboard loading and store-selection feedback are announced accessibly", () => {
  assert.match(dashboard, /id="notice" role="status" aria-live="polite"/);
  assert.match(dashboard, /id="status" aria-live="polite"/);
});

test("dashboard backend dependencies have bounded network waits", () => {
  const merchant = readFileSync("supabase/functions/henvalt-merchant-dashboard/index.ts", "utf8");
  const legacy = readFileSync("supabase/functions/henvalt-dashboard/index.ts", "utf8");
  assert.ok((merchant.match(/AbortSignal\\.timeout/g) || []).length >= 3);
  assert.ok((legacy.match(/AbortSignal\\.timeout/g) || []).length >= 2);
});

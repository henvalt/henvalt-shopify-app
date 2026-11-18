import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { isSingleActiveStoreScope } from "../supabase/functions/_shared/dashboard-store-scope.mjs";

const shopifyDashboard = readFileSync(
  new URL("../supabase/functions/henvalt-dashboard/index.ts", import.meta.url),
  "utf8",
);
const merchantDashboard = readFileSync(
  new URL("../supabase/functions/henvalt-merchant-dashboard/index.ts", import.meta.url),
  "utf8",
);

test("dashboard scope accepts only one active connection and the selected connection", () => {
  assert.equal(isSingleActiveStoreScope([{ id: "store-a", active: true }]), true);
  assert.equal(isSingleActiveStoreScope([{ id: "store-a", active: true }], "store-a"), true);
  assert.equal(isSingleActiveStoreScope([{ id: "store-a", active: true }], "store-b"), false);
  assert.equal(isSingleActiveStoreScope([
    { id: "store-a", active: true },
    { id: "store-b", active: false },
  ]), false);
  assert.equal(isSingleActiveStoreScope([
    { id: "store-a", active: true },
    { id: "store-b", active: true },
  ]), false);
  assert.equal(isSingleActiveStoreScope([{ id: "store-a", active: false }]), false);
  assert.equal(isSingleActiveStoreScope(null), false);
});

test("Shopify-session dashboard validates all tenant connections before calling tenant-wide summary", () => {
  assert.doesNotMatch(shopifyDashboard, /const URL =/);
  assert.match(shopifyDashboard, /new URL\(req\.url\)/);
  assert.match(shopifyDashboard, /control_plane_shop_connection/);
  assert.match(shopifyDashboard, /shopify_connections\?select=id,active&tenant_id=eq\./);
  assert.match(shopifyDashboard, /isSingleActiveStoreScope\(tenantConnections, connection\.connection_id\)/);
  const guard = shopifyDashboard.indexOf("isSingleActiveStoreScope(tenantConnections");
  const summary = shopifyDashboard.indexOf('rpc("control_plane_dashboard_summary"');
  assert.ok(guard >= 0 && summary > guard, "The store-scope guard must run before the summary RPC");
  assert.match(shopifyDashboard, /store_specific_metrics_unavailable/);
});

test("merchant dashboard includes inactive historical connections in its single-store guard", () => {
  assert.match(merchantDashboard, /shopify_connections\?select=id,shop_domain,active,tenants!inner\(status\)/);
  assert.doesNotMatch(merchantDashboard, /&active=eq\.true/);
  assert.match(merchantDashboard, /isSingleActiveStoreScope\(connections\)/);
  const guard = merchantDashboard.indexOf("isSingleActiveStoreScope(connections)");
  const summary = merchantDashboard.indexOf("control_plane_dashboard_summary");
  assert.ok(guard >= 0 && summary > guard, "The store-scope guard must run before the summary RPC");
  assert.match(merchantDashboard, /store_specific_metrics_unavailable/);
});

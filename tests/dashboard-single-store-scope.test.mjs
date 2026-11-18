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

test("Shopify-session dashboard uses its authenticated exact connection for V2 metrics", () => {
  assert.match(shopifyDashboard, /new URL\\(req\\.url\\)/);
  assert.match(shopifyDashboard, /control_plane_shop_connection/);
  assert.match(shopifyDashboard, /control_plane_dashboard_summary_v2/);
  assert.match(shopifyDashboard, /p_shopify_connection_id: connection\\.connection_id/);
  assert.doesNotMatch(shopifyDashboard, /isSingleActiveStoreScope|control_plane_dashboard_summary"/);
});

test("merchant dashboard requires an explicit store selection when multiple active stores exist", () => {
  assert.match(merchantDashboard, /shopify_connections\\?select=id,shop_domain,active,tenants!inner\\(status\\)/);
  assert.match(merchantDashboard, /&active=eq\\.true/);
  assert.match(merchantDashboard, /requestedConnectionId/);
  assert.match(merchantDashboard, /store_selection_required/);
  assert.match(merchantDashboard, /stores: connections\\.map/);
  assert.match(merchantDashboard, /control_plane_dashboard_summary_v2/);
  assert.match(merchantDashboard, /p_shopify_connection_id: selectedConnection\\.id/);
  assert.doesNotMatch(merchantDashboard, /isSingleActiveStoreScope|control_plane_dashboard_summary"/);
});

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
const dashboardHtml = readFileSync(
  new URL("../dashboard/index.html", import.meta.url),
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
  assert.ok(shopifyDashboard.includes("new URL(req.url)"));
  assert.ok(shopifyDashboard.includes("control_plane_shop_connection"));
  assert.ok(shopifyDashboard.includes("control_plane_dashboard_summary_v2"));
  assert.ok(shopifyDashboard.includes("p_shopify_connection_id: connection.connection_id"));
  assert.ok(!shopifyDashboard.includes("isSingleActiveStoreScope"));
  assert.ok(!shopifyDashboard.includes('rpc("control_plane_dashboard_summary"'));
});

test("merchant dashboard requires an explicit store selection when multiple active stores exist", () => {
  assert.ok(merchantDashboard.includes("shopify_connections?select=id,shop_domain,active,tenants!inner(status)"));
  assert.ok(merchantDashboard.includes("&active=eq.true"));
  assert.ok(merchantDashboard.includes("requestedConnectionId"));
  assert.ok(merchantDashboard.includes("shopify_app_registry?select=app_key&lifecycle_status=eq.active"));
  assert.ok(merchantDashboard.includes('"&app_key=" + appKeyFilter +'));
  assert.ok(merchantDashboard.includes("shopify_shop_id=not.is.null"));
  assert.ok(merchantDashboard.includes("access_token_secret_ref=not.is.null"));
  assert.ok(merchantDashboard.includes("refresh_token_secret_ref=not.is.null"));
  assert.ok(merchantDashboard.includes("reauth_required_at=is.null"));
  assert.ok(merchantDashboard.includes("owner_controlled_shop_connection_required"));
  assert.ok(merchantDashboard.includes("store_selection_required"));
  assert.ok(merchantDashboard.includes("stores: connections.map"));
  assert.ok(merchantDashboard.includes("control_plane_dashboard_summary_v2"));
  assert.ok(merchantDashboard.includes("p_shopify_connection_id: selectedConnection.id"));
  assert.ok(!merchantDashboard.includes("isSingleActiveStoreScope"));
  assert.ok(!merchantDashboard.includes('control_plane_dashboard_summary"'));
});

test("dashboard UI selects one store and never combines unlike currencies", () => {
  assert.ok(dashboardHtml.includes('id="storeSelect"'));
  assert.ok(dashboardHtml.includes("shopify_connection_id="));
  assert.ok(dashboardHtml.includes("store_selection_required"));
  assert.ok(dashboardHtml.includes("Multiple currencies"));
  assert.ok(dashboardHtml.includes("x.currency||currency"));
});

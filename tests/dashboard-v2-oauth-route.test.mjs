import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const dashboard = readFileSync(new URL("../dashboard/index.html", import.meta.url), "utf8");

test("dashboard Shopify connection uses the V2 owner-authenticated install route", () => {
  assert.match(dashboard, /functions\/v1\/henvalt-shopify-oauth-v2\/install/);
  assert.doesNotMatch(dashboard, /functions\/v1\/henvalt-shopify-oauth\/auth/);
  assert.match(dashboard, /Authorization:\s*"Bearer "\+session\.access_token/);
  assert.match(dashboard, /JSON\.stringify\(\{shop\}\)/);
  assert.match(dashboard, /canonical \*\.myshopify\.com domain/);
  assert.match(dashboard, /app registry, Vault secret, and owner-controlled endpoints must be ready first/);
  assert.match(dashboard, /owner_controlled_shop_connection_required/);
  assert.match(dashboard, /No owner-controlled Shopify connection yet/);
});

test("dashboard connection UI does not claim to reinstall or authorize a legacy app", () => {
  assert.match(dashboard, /Connect the configured HENVALT Shopify app/);
  assert.doesNotMatch(dashboard, /existing HENVALT OAuth Connection app/);
});

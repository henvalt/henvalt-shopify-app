import test from "node:test";
import assert from "node:assert/strict";
import { normalizeShopDomain, resolveTrustedShopifyIdentity } from "../cloudflare/shopify-identity.js";

const appKey = "legacy";
const shop = "merchant-a.myshopify.com";
const connection = {
  id: "123e4567-e89b-42d3-a456-426614174000",
  tenant_id: "223e4567-e89b-42d3-a456-426614174000",
  shop_domain: shop,
  app_key: appKey,
  active: true,
  reauth_required_at: null,
};

test("normalizes valid Shopify domains and rejects non-Shopify or malformed domains", () => {
  assert.equal(normalizeShopDomain(" MERCHANT-A.myshopify.com "), shop);
  assert.equal(normalizeShopDomain("merchant-a.myshopify.com."), shop);
  assert.equal(normalizeShopDomain("merchant-a.example.com"), null);
  assert.equal(normalizeShopDomain("https://merchant-a.myshopify.com"), null);
  assert.equal(normalizeShopDomain("merchant_a.myshopify.com"), null);
  assert.equal(normalizeShopDomain(null), null);
});

test("returns a minimal immutable trusted identity for an exact active app/store binding", () => {
  const result = resolveTrustedShopifyIdentity({ appKey, shopDomain: shop, connection });
  assert.equal(result.ok, true);
  assert.deepEqual(result.identity, {
    appKey,
    connectionId: connection.id,
    tenantId: connection.tenant_id,
    shopDomain: shop,
  });
  assert.equal(Object.isFrozen(result.identity), true);
  assert.equal("access_token_secret_ref" in result.identity, false);
});

test("fails closed for missing or invalid app identity and connection", () => {
  assert.equal(resolveTrustedShopifyIdentity(null).code, "IDENTITY_INPUT_MISSING");
  assert.equal(resolveTrustedShopifyIdentity({ appKey: "BAD KEY", shopDomain: shop, connection }).code, "APP_KEY_INVALID");
  assert.equal(resolveTrustedShopifyIdentity({ appKey, shopDomain: shop, connection: null }).code, "SHOP_CONNECTION_NOT_FOUND");
  assert.equal(resolveTrustedShopifyIdentity({ appKey, shopDomain: "not-a-shop", connection }).code, "SHOP_DOMAIN_INVALID");
});

test("rejects app-key mismatch and legacy NULL app-key without fallback", () => {
  assert.equal(resolveTrustedShopifyIdentity({
    appKey: "public_v1", shopDomain: shop, connection,
  }).code, "SHOP_APP_IDENTITY_MISMATCH");
  assert.equal(resolveTrustedShopifyIdentity({
    appKey, shopDomain: shop, connection: { ...connection, app_key: null },
  }).code, "SHOP_APP_IDENTITY_MISMATCH");
});

test("rejects domain, tenant, and connection identity mismatches", () => {
  assert.equal(resolveTrustedShopifyIdentity({
    appKey, shopDomain: shop, connection: { ...connection, shop_domain: "merchant-b.myshopify.com" },
  }).code, "SHOP_DOMAIN_MISMATCH");
  assert.equal(resolveTrustedShopifyIdentity({
    appKey, shopDomain: shop, connection: { ...connection, tenant_id: "not-a-uuid" },
  }).code, "SHOP_CONNECTION_IDENTITY_INVALID");
  assert.equal(resolveTrustedShopifyIdentity({
    appKey, shopDomain: shop, connection: { ...connection, id: "not-a-uuid" },
  }).code, "SHOP_CONNECTION_IDENTITY_INVALID");
});

test("rejects inactive and reauthentication-required connections", () => {
  assert.equal(resolveTrustedShopifyIdentity({
    appKey, shopDomain: shop, connection: { ...connection, active: false },
  }).code, "SHOP_CONNECTION_INACTIVE");
  assert.equal(resolveTrustedShopifyIdentity({
    appKey, shopDomain: shop, connection: { ...connection, reauth_required_at: "2026-11-16T00:00:00Z" },
  }).code, "SHOP_CONNECTION_INACTIVE");
});

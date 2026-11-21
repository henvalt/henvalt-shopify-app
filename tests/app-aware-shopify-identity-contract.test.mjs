import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const adr = readFileSync(
  new URL("../docs/adr/001-app-aware-shopify-identity-rollout.md", import.meta.url),
  "utf8",
);
const contract = readFileSync(
  new URL("../docs/app-aware-shopify-identity-implementation-contract-v1.md", import.meta.url),
  "utf8",
);
const matrix = readFileSync(
  new URL("../docs/store-isolation-regression-matrix.md", import.meta.url),
  "utf8",
);
const preflight = readFileSync(
  new URL("../docs/sql/app-aware-shopify-identity-preflight-review-only.sql", import.meta.url),
  "utf8",
);

test("initial app-aware rollout preserves one HENVALT app identity per Shopify shop", () => {
  for (const phrase of [
    "one HENVALT app identity per Shopify shop domain",
    "shopify_connections.shop_domain",
    "SHOP_ALREADY_CONNECTED_TO_DIFFERENT_HENVALT_APP",
    "must never be called for `public_v1`",
    "No production change is authorized",
  ]) {
    assert.ok(adr.includes(phrase), `ADR missing invariant: ${phrase}`);
  }
});

test("app-aware identity contract keeps legacy functions and credentials isolated", () => {
  for (const phrase of [
    "app_key + shopify_connection_id + tenant_id + normalized_shop_domain",
    "finalize_shopify_oauth_install_v2",
    "verify_shopify_webhook_hmac_v2",
    "resolve_shopify_connection_v2",
    "claim_shopify_token_refresh_v2",
    "Legacy OAuth finalizers remain legacy-only. They must not be called by public app callbacks",
    "No app key fallback to legacy",
    "HENVALT_RECOVERY",
    "HENVALT_DELIVERY",
    "Billing principal",
  ]) {
    assert.ok(contract.includes(phrase), `contract missing: ${phrase}`);
  }
});

test("app-aware preflight is SELECT-only and does not mutate production", () => {
  const normalized = preflight.toLowerCase();
  assert.match(normalized, /review only/);
  assert.match(normalized, /select/);
  assert.doesNotMatch(
    normalized,
    /^\\s*(insert|update|delete|alter|create|drop|truncate|grant|revoke)\\b/im,
    "preflight must contain no executable mutation statements",
  );
  assert.doesNotMatch(normalized, /vault\\.(create_secret|update_secret)/);
});


test("regression matrix covers cross-app OAuth, HMAC, collision and rollback cases", () => {
  for (const id of [
    "APP-01", "APP-02", "APP-03", "APP-04", "APP-05", "APP-06",
    "APP-07", "APP-08", "APP-09", "APP-10", "APP-11", "APP-12",
    "APP-13", "APP-14", "APP-15", "APP-16", "APP-17", "APP-18",
  ]) {
    assert.ok(matrix.includes(`| ${id} |`), `regression matrix missing: ${id}`);
  }
});

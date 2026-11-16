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
    "Never choose credentials from callback parameters",
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
  for (const forbidden of [
    "insert into",
    "update ",
    "delete from",
    "alter table",
    "create table",
    "drop table",
    "create or replace function",
    "vault.create_secret",
    "vault.update_secret",
  ]) {
    assert.ok(!normalized.includes(forbidden), `preflight contains forbidden mutation: ${forbidden}`);
  }
});

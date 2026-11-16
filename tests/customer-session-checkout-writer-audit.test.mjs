import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const audit = readFileSync(
  new URL("../docs/customer-session-checkout-writer-audit.md", import.meta.url),
  "utf8"
);

test("customer identity is connection-scoped and email is not an identity fallback", () => {
  assert.match(audit, /upsert_customer/);
  assert.match(audit, /tenant plus case-insensitive email/);
  assert.match(audit, /Email is a contact attribute, not proof of Shopify store identity/);
  assert.match(audit, /Do not use email as an identity fallback/);
});

test("session and alias keys require exact Shopify connection scope", () => {
  assert.match(audit, /bind_session_alias/);
  assert.match(audit, /\(tenant_id, session_reference\)/);
  assert.match(audit, /\(tenant_id, alias_reference\)/);
  assert.match(audit, /\(shopify_connection_id, session_reference\)/);
  assert.match(audit, /\(shopify_connection_id, alias_reference\)/);
});

test("identity resolution and checkout writes cannot rely on tenant-only keys", () => {
  assert.match(audit, /resolve_identity/);
  assert.match(audit, /upsert_checkout/);
  assert.match(audit, /tenant-wide unique key on/);
  assert.match(audit, /\(shopify_connection_id, shopify_checkout_id\)/);
});

test("V1 production functions remain untouched until all consumers are safe", () => {
  assert.match(audit, /Do not retrofit these existing V1 functions in place yet/);
  assert.match(audit, /Keep historical rows with null connection unresolved/);
  assert.match(audit, /No V2 identity writer, new table, migration, or production function replacement was created/);
});

test("two-store regression cases cover reused external identifiers and consent", () => {
  for (const phrase of [
    "same Shopify customer ID",
    "same email with different Shopify customer IDs",
    "same session reference",
    "same alias/checkout token",
    "same Shopify checkout ID",
    "Consent-disabled events persist no customer, session, alias or checkout identity references"
  ]) assert.ok(audit.includes(phrase), `Missing regression requirement: ${phrase}`);
});

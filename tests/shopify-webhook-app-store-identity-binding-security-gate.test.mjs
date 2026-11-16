import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

test("webhook identity design treats Shopify HMAC as body-only and binds route to store", () => {
  const doc = readFileSync(
    new URL("../docs/shopify-webhook-app-store-identity-binding-security-gate.md", import.meta.url),
    "utf8",
  );
  for (const phrase of [
    "does **not** cryptographically bind",
    "per-connection webhook route token",
    "Select that app's Vault secret",
    "changed header B is rejected",
    "tenant is derived from the connection",
    "false 200 acknowledgement",
    "No app secret was read or printed",
    "requires separate explicit authorization",
  ]) {
    assert.ok(doc.includes(phrase), `Missing webhook identity security requirement: ${phrase}`);
  }
});

test("webhook identity design explicitly preserves preparation-only boundary", () => {
  const doc = readFileSync(
    new URL("../docs/shopify-webhook-app-store-identity-binding-security-gate.md", import.meta.url),
    "utf8",
  );
  assert.match(doc, /No production schema, row, function, Vault entry, Cloudflare binding, n8n workflow, Shopify webhook subscription/);
  assert.match(doc, /Implementation\/cutover requires separate explicit authorization/);
});

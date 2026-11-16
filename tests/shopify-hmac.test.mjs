import test from "node:test";
import assert from "node:assert/strict";
import { webcrypto } from "node:crypto";
import { verifyShopifyWebhookHmac } from "../cloudflare/shopify-hmac.mjs";

async function sign(raw, secret) {
  const key = await webcrypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const signature = new Uint8Array(await webcrypto.subtle.sign("HMAC", key, raw));
  return Buffer.from(signature).toString("base64");
}

test("accepts a valid HMAC over exact UTF-8 request bytes", async () => {
  const raw = new TextEncoder().encode(JSON.stringify({ product: "café", emoji: "🛍️" }));
  const hmac = await sign(raw, "test-shopify-secret");
  assert.equal(await verifyShopifyWebhookHmac(raw, "test-shopify-secret", hmac, webcrypto), true);
});

test("rejects a body changed by even one byte", async () => {
  const raw = new TextEncoder().encode('{"amount":10}');
  const hmac = await sign(raw, "test-shopify-secret");
  const changed = new TextEncoder().encode('{"amount":11}');
  assert.equal(await verifyShopifyWebhookHmac(changed, "test-shopify-secret", hmac, webcrypto), false);
});

test("rejects wrong secrets and malformed signatures", async () => {
  const raw = new TextEncoder().encode('{"ok":true}');
  const hmac = await sign(raw, "right-secret");
  assert.equal(await verifyShopifyWebhookHmac(raw, "wrong-secret", hmac, webcrypto), false);
  for (const invalid of ["", "not-base64", "A".repeat(43), "A".repeat(44)]) {
    assert.equal(await verifyShopifyWebhookHmac(raw, "right-secret", invalid, webcrypto), false);
  }
});

test("fails closed for missing secret or non-byte body", async () => {
  assert.equal(await verifyShopifyWebhookHmac("{}", "secret", "A".repeat(44), webcrypto), false);
  assert.equal(await verifyShopifyWebhookHmac(new Uint8Array(), "", "A".repeat(44), webcrypto), false);
});

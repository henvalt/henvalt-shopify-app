import test from "node:test";
import assert from "node:assert/strict";
import { createHmac, timingSafeEqual } from "node:crypto";

const secret = "offline-only-synthetic-shopify-secret";

function signature(raw, key = secret) {
  return createHmac("sha256", key).update(Buffer.from(raw, "utf8")).digest("base64");
}

function verify(raw, supplied, key = secret) {
  const expected = Buffer.from(signature(raw, key), "utf8");
  const actual = Buffer.from(supplied, "utf8");
  return expected.length === actual.length && timingSafeEqual(expected, actual);
}

test("synthetic Shopify privacy webhook signature validates exact raw UTF-8 body", () => {
  const raw = JSON.stringify({ shop_id: 123, shop_domain: "offline.myshopify.com", customer: { id: "456" } });
  assert.equal(verify(raw, signature(raw)), true);
});

test("a one-byte body change invalidates the signature", () => {
  const raw = JSON.stringify({ shop_id: 123, shop_domain: "offline.myshopify.com" });
  assert.equal(verify(raw + " ", signature(raw)), false);
});

test("a different app secret invalidates the signature", () => {
  const raw = JSON.stringify({ data_request: { id: 789 } });
  assert.equal(verify(raw, signature(raw, "wrong-secret")), false);
});

test("unicode payload is signed as exact UTF-8 bytes", () => {
  const raw = JSON.stringify({ customer_note: "Crème brûlée 🍮" });
  const signed = signature(raw);
  assert.equal(verify(raw, signed), true);
  assert.equal(verify(raw.normalize("NFD"), signed), false);
});

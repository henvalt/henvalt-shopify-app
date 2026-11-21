import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const read = (path) => readFileSync(new URL(path, import.meta.url), "utf8");

const outboundFiles = [
  ["checkout V2 delivery", "../supabase/functions/henvalt-shopify-contact-delivery-v2/index.ts"],
  ["pixel V2 delivery", "../supabase/functions/henvalt-shopify-pixel-delivery-v2/index.ts"],
  ["MailerSend preflight helper", "../supabase/functions/_shared/recovery-message-v2.mjs"],
];

test("every authenticated V2 outbound fetch rejects redirects", () => {
  for (const [label, path] of outboundFiles) {
    const source = read(path);
    const fetchCalls = (source.match(/fetch(?:er)?\(/g) ?? []).length;
    const redirectGuards = (source.match(/redirect:\s*["']error["']/g) ?? []).length;
    assert.ok(fetchCalls > 0, `${label}: expected outbound fetch call sites`);
    assert.equal(redirectGuards, fetchCalls, `${label}: every fetch must set redirect: "error"`);
  }
});

test("provider submission endpoints remain fixed while redirect following is disabled", () => {
  const checkout = read("../supabase/functions/henvalt-shopify-contact-delivery-v2/index.ts");
  const pixel = read("../supabase/functions/henvalt-shopify-pixel-delivery-v2/index.ts");
  assert.ok(checkout.includes('fetch("https://api.mailersend.com/v1/email",{method:"POST",redirect:"error"'));
  assert.match(pixel, /fetch\("https:\/\/api\.mailersend\.com\/v1\/email",\{\s*method:"POST",redirect:"error"/);
});

test("Shopify access tokens are only sent to strictly validated myshopify hosts", () => {
  const checkout = read("../supabase/functions/henvalt-shopify-contact-delivery-v2/index.ts");
  const pixel = read("../supabase/functions/henvalt-shopify-pixel-delivery-v2/index.ts");
  for (const source of [checkout, pixel]) {
    assert.ok(source.includes("const validShopDomain=(v:string)=>/^[a-z0-9]"));
  }
  assert.ok(checkout.includes("if(!validShopDomain(shop))return false"));
  assert.ok(checkout.includes("if(!validShopDomain(shop))return null"));
  assert.ok(checkout.includes("if(!validShopDomain(shop)||!access"));
  assert.ok(pixel.includes('if(!validShopDomain(shop))throw new Error("SHOPIFY_LOOKUP_FAILED")'));
  assert.ok(pixel.includes("if(!validShopDomain(shop)||shopToken.length"));
});

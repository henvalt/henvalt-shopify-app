import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const source = readFileSync(new URL("../supabase/functions/henvalt-shopify-oauth-v2/index.ts", import.meta.url), "utf8");
const supabaseConfig = readFileSync(new URL("../supabase/config.toml", import.meta.url), "utf8");

test("OAuth V2 uses owner-configured infrastructure endpoints instead of partner-owned Worker hosts", () => {
  assert.match(source, /Deno\.env\.get\(["']SHOPIFY_WEBHOOK_INGRESS_BASE_URL["']\)/);
  assert.match(source, /Deno\.env\.get\(["']SHOPIFY_PIXEL_COLLECTOR_URL["']\)/);
  assert.doesNotMatch(source, /chmuhammadrehan18\.workers\.dev/i);
  assert.match(source, /collectorUrl: SHOPIFY_PIXEL_COLLECTOR_URL/);
  assert.match(source, /new URL\(SHOPIFY_WEBHOOK_INGRESS_BASE_URL\)\.origin/);
});

test("OAuth V2 fails closed unless ingress is an HTTPS origin and collector is the HTTPS events endpoint", () => {
  assert.match(source, /function validHttpsOrigin\(value: string\)/);
  assert.match(source, /function validPixelCollectorUrl\(value: string\)/);
  assert.match(source, /url\.protocol === "https:"/);
  assert.match(source, /url\.pathname === "\/v1\/events"/);
  assert.match(source, /validHttpsOrigin\(SHOPIFY_WEBHOOK_INGRESS_BASE_URL\)/);
  assert.match(source, /validPixelCollectorUrl\(SHOPIFY_PIXEL_COLLECTOR_URL\)/);
  assert.match(source, /function configOk\(\): boolean/);
});

test("OAuth V2 rejects a redirect secret that does not exactly match its own callback route", () => {
  assert.match(source, /function validOAuthRedirectUri\(value: string\)/);
  assert.match(source, /redirect\.origin === supabase\.origin/);
  assert.match(source, /redirect\.pathname === "\/functions\/v1\/henvalt-shopify-oauth-v2\/callback"/);
  assert.match(source, /validOAuthRedirectUri\(SHOPIFY_REDIRECT_URI\)/);
});

test("Shopify OAuth and webhook callbacks bypass gateway JWT only because handlers verify their own credentials", () => {
  for (const slug of [
    "henvalt-shopify-oauth-v2",
    "henvalt-shopify-privacy-v2",
    "henvalt-shopify-webhook-ingress",
  ]) {
    const escaped = slug.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
    const section = new RegExp("\\[functions\\." + escaped + "\\]\\s*\\n(?:[^\\[]*\\n)*?verify_jwt = false");
    assert.match(supabaseConfig, section, slug + " must disable gateway JWT for its custom-authenticated callback");
  }
  assert.match(source, /authenticated_merchant_required/);
  assert.match(source, /invalid_merchant_session/);
});

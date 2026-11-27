import test from "node:test";
import assert from "node:assert/strict";
import { buildShopifyCompletionUrl, isSafeCompletionDashboardUrl } from "../supabase/functions/henvalt-shopify-oauth/completion-url.mjs";

test("OAuth completion requires an explicit HTTPS dashboard URL", () => {
  assert.equal(isSafeCompletionDashboardUrl(undefined), false);
  assert.equal(isSafeCompletionDashboardUrl(""), false);
  assert.equal(buildShopifyCompletionUrl(undefined, {
    shop: "synthetic.myshopify.com",
    pixelStatus: "active",
    webhooksStatus: "verified",
  }), null);
});

test("OAuth completion honours the explicitly configured dashboard origin", () => {
  const result = new URL(buildShopifyCompletionUrl("https://staging-dashboard.example.test/app", {
    shop: "synthetic.myshopify.com",
    pixelStatus: "active",
    webhooksStatus: "verified",
  }));
  assert.equal(result.origin, "https://staging-dashboard.example.test");
  assert.equal(result.pathname, "/settings");
  assert.equal(result.searchParams.get("shopify_status"), "connected");
  assert.equal(result.searchParams.get("shop"), "synthetic.myshopify.com");
  assert.equal(result.searchParams.get("pixel_status"), "active");
  assert.equal(result.searchParams.get("webhooks_status"), "verified");
});

test("OAuth completion rejects unsafe or malformed dashboard redirect configuration", () => {
  for (const configured of [
    "javascript:alert(1)",
    "http://dashboard.example.test",
    "https://user:pass@dashboard.example.test",
    "https://dashboard.example.test/?next=https://evil.invalid",
    "https://dashboard.example.test/#fragment",
    "not a url",
  ]) {
    assert.equal(isSafeCompletionDashboardUrl(configured), false);
    assert.equal(buildShopifyCompletionUrl(configured, {
      shop: "synthetic.myshopify.com",
      pixelStatus: "unknown",
      webhooksStatus: "unknown",
    }), null);
  }
});

import test from "node:test";
import assert from "node:assert/strict";
import { buildShopifyCompletionUrl } from "../supabase/functions/henvalt-shopify-oauth/completion-url.mjs";

test("OAuth completion defaults to the current Pages dashboard, not the retired Lovable host", () => {
  const result = new URL(buildShopifyCompletionUrl(undefined, {
    shop: "synthetic.myshopify.com",
    pixelStatus: "active",
    webhooksStatus: "verified",
  }));
  assert.equal(result.origin, "https://henvalt-dashboard.pages.dev");
  assert.equal(result.pathname, "/settings");
  assert.equal(result.searchParams.get("shopify_status"), "connected");
  assert.equal(result.searchParams.get("shop"), "synthetic.myshopify.com");
  assert.equal(result.searchParams.get("pixel_status"), "active");
  assert.equal(result.searchParams.get("webhooks_status"), "verified");
});

test("OAuth completion honours a configured HTTPS dashboard origin", () => {
  const result = new URL(buildShopifyCompletionUrl("https://dashboard.example.test/app", {
    shop: "synthetic.myshopify.com",
    pixelStatus: "attention",
    webhooksStatus: "attention",
    pixelIssue: "PIXEL_ACTIVATION_UNAVAILABLE",
  }));
  assert.equal(result.origin, "https://dashboard.example.test");
  assert.equal(result.pathname, "/settings");
  assert.equal(result.searchParams.get("pixel_issue"), "PIXEL_ACTIVATION_UNAVAILABLE");
});

test("OAuth completion rejects unsafe or malformed dashboard redirect configuration", () => {
  for (const configured of ["javascript:alert(1)", "http://dashboard.example.test", "https://user:pass@dashboard.example.test", "not a url"]) {
    const result = new URL(buildShopifyCompletionUrl(configured, {
      shop: "synthetic.myshopify.com",
      pixelStatus: "unknown",
      webhooksStatus: "unknown",
    }));
    assert.equal(result.origin, "https://henvalt-dashboard.pages.dev");
  }
});

import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const audit = readFileSync(
  new URL("../docs/live-shopify-edge-function-app-identity-audit.md", import.meta.url),
  "utf8",
);

test("Edge Function audit records single-app OAuth and token refresh contracts", () => {
  for (const phrase of [
    "OAuth Edge Function is single-app",
    "SHOPIFY_API_KEY",
    "SHOPIFY_API_SECRET",
    "SHOPIFY_REDIRECT_URI",
    "control_plane_finalize_shopify_oauth_install_expiring_for_owner",
    "Token refresh Edge Function is single-app and shop-domain keyed",
    "exact connection ID",
  ]) {
    assert.ok(audit.includes(phrase), `Edge Function audit missing: ${phrase}`);
  }
});

test("Edge Function audit records pixel/control-plane boundaries and no-deploy rule", () => {
  for (const phrase of [
    "Pixel ingestion proxy delegates identity to the pixel key",
    "pixel_keys.shopify_connection_id",
    "Control Plane Edge Function is shop-domain keyed",
    "No Edge Function was edited or deployed",
    "does not authorize a new Shopify app registration",
  ]) {
    assert.ok(audit.includes(phrase), `Edge Function safety requirement missing: ${phrase}`);
  }
});

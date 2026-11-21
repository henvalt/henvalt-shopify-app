import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const appConfig = readFileSync(new URL("../shopify.app.toml", import.meta.url), "utf8");
const oauthV2 = readFileSync(new URL("../supabase/functions/henvalt-shopify-oauth-v2/index.ts", import.meta.url), "utf8");
const legacyOAuth = readFileSync(new URL("../supabase/functions/henvalt-shopify-oauth/index.ts", import.meta.url), "utf8");

test("Shopify app callback URL targets the app-aware OAuth V2 Edge Function", () => {
  assert.match(appConfig, /henvalt-shopify-oauth-v2\/callback/);
  assert.doesNotMatch(appConfig, /henvalt-shopify-oauth\/callback/);
  assert.match(oauthV2, /route === "callback"/);
  assert.match(oauthV2, /control_plane_finalize_shopify_oauth_install_app_aware/);
});

test("app-aware OAuth callback registers per-install V2 webhook routes", () => {
  assert.match(oauthV2, /p_route_token: routeToken/);
  assert.match(oauthV2, /\/shopify\/webhooks\/\$\{routeToken\}/);
  assert.match(oauthV2, /destination: "per-install-v2-route"/);
  assert.match(legacyOAuth, /\/shopify\/webhooks"/);
});

import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const source = readFileSync(new URL("../supabase/functions/henvalt-shopify-oauth-v2/index.ts", import.meta.url), "utf8");

test("OAuth V2 resolves app identity and secret server-side from the configured client ID", () => {
  assert.match(source, /resolve_shopify_app_oauth_identity/);
  assert.match(source, /p_shopify_client_id: SHOPIFY_API_KEY/);
  assert.match(source, /data\.shopify_api_secret/);
  assert.doesNotMatch(source, /Deno\.env\.get\(["']SHOPIFY_API_SECRET["']\)/);
});

test("OAuth health reports ready only when an active Vault-backed app identity resolves", () => {
  const health = source.slice(source.indexOf('if (route === "health"'), source.indexOf('if (!configOk())', source.indexOf('if (route === "health"')));
  assert.match(health, /resolveAppIdentity\(\)/);
  assert.match(health, /app_identity_ready: ready/);
  assert.match(health, /configured: false, app_identity_ready: false/);
  assert.doesNotMatch(health, /shopify_api_secret|appKey|clientId/);
});

test("OAuth state is bound to the resolved app and callback rejects cross-app state", () => {
  assert.match(source, /app_key: appIdentity\.appKey/);
  assert.match(source, /initiated_by_user_id,app_key/);
  assert.match(source, /row\.app_key !== appIdentity\.appKey/);
  assert.match(source, /verifyCallbackHmac\(url\.searchParams, appIdentity\.secret\)/);
});

test("OAuth finalization provisions a per-install V2 route without persisting its raw token in audit", () => {
  assert.match(source, /control_plane_finalize_shopify_oauth_install_app_aware/);
  assert.match(source, /crypto\.getRandomValues\(new Uint8Array\(32\)\)/);
  assert.match(source, /p_route_token: routeToken/);
  assert.match(source, /\/shopify\/webhooks\/\$\{routeToken\}/);
  assert.match(source, /destination: "per-install-v2-route"/);
  assert.doesNotMatch(source, /console\.(log|error|warn)\([^\n]*routeToken/i);
});

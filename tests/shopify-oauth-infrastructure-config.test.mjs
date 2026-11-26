import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { isOAuthCallbackBoundToSupabase, resolveOAuthInfrastructure } from "../supabase/functions/henvalt-shopify-oauth/infrastructure-config.mjs";

test("OAuth requires explicitly configured HTTPS ingress and pixel collector endpoints", () => {
  const result = resolveOAuthInfrastructure({
    ingressBaseUrl: "https://ingress.example.invalid",
    pixelCollectorUrl: "https://pixel.example.invalid/v1/events",
  });
  assert.deepEqual(result, {
    valid: true,
    webhookUri: "https://ingress.example.invalid/shopify/webhooks",
    pixelCollectorUrl: "https://pixel.example.invalid/v1/events",
  });
});

test("OAuth infrastructure rejects missing, insecure, credentialed, or malformed endpoints", () => {
  for (const config of [
    { ingressBaseUrl: "", pixelCollectorUrl: "https://pixel.example.invalid/v1/events" },
    { ingressBaseUrl: "http://ingress.example.invalid", pixelCollectorUrl: "https://pixel.example.invalid/v1/events" },
    { ingressBaseUrl: "https://user:pass@ingress.example.invalid", pixelCollectorUrl: "https://pixel.example.invalid/v1/events" },
    { ingressBaseUrl: "https://ingress.example.invalid/path", pixelCollectorUrl: "https://pixel.example.invalid/v1/events" },
    { ingressBaseUrl: "https://ingress.example.invalid", pixelCollectorUrl: "https://pixel.example.invalid/other" },
  ]) assert.equal(resolveOAuthInfrastructure(config).valid, false);
});

test("OAuth callback must be the exact callback path on the configured Supabase project", () => {
  assert.equal(isOAuthCallbackBoundToSupabase(
    "https://staging-project.supabase.co",
    "https://staging-project.supabase.co/functions/v1/henvalt-shopify-oauth/callback",
  ), true);
  assert.equal(isOAuthCallbackBoundToSupabase(
    "https://staging-project.supabase.co",
    "https://production-project.supabase.co/functions/v1/henvalt-shopify-oauth/callback",
  ), false);
  for (const redirect of [
    "http://staging-project.supabase.co/functions/v1/henvalt-shopify-oauth/callback",
    "https://staging-project.supabase.co/functions/v1/other/callback",
    "https://user:pass@staging-project.supabase.co/functions/v1/henvalt-shopify-oauth/callback",
    "https://staging-project.supabase.co/functions/v1/henvalt-shopify-oauth/callback?next=https://evil.invalid",
  ]) assert.equal(isOAuthCallbackBoundToSupabase("https://staging-project.supabase.co", redirect), false);
});

test("Shopify app version creation is manual and explicitly opt-in", () => {
  const workflow = readFileSync(".github/workflows/shopify-config-validation.yml", "utf8");
  assert.match(workflow, /workflow_dispatch:/);
  assert.match(workflow, /deploy-shopify-version:\n\s+# Version creation is an explicit operator action/);
  assert.match(workflow, /if: github\.event_name == 'workflow_dispatch' && vars\.HENVALT_ALLOW_SHOPIFY_VERSION_CREATION == 'true'/);
  assert.doesNotMatch(workflow, /if: github\.event_name != 'pull_request'/);
});

test("Shopify static configuration validation runs on the active candidate branch", () => {
  const workflow = readFileSync(".github/workflows/shopify-config-validation.yml", "utf8");
  assert.match(workflow, /push:\s*\n\s*branches: \[main, work\/48h-system-readiness-2026-11-21\]/);
  assert.match(workflow, /static-validation:/);
});

test("OAuth refuses to start without an explicit completion dashboard URL", () => {
  const source = readFileSync("supabase/functions/henvalt-shopify-oauth/index.ts", "utf8");
  assert.match(source, /Deno\.env\.get\("HENVALT_DASHBOARD_URL"\)\s*\?\?\s*""/);
  assert.match(source, /isSafeCompletionDashboardUrl\(HENVALT_DASHBOARD_URL\)/);
  assert.doesNotMatch(source, /HENVALT_DASHBOARD_URL[^\n]*henvalt-dashboard\.pages\.dev/);
  const helper = readFileSync("supabase/functions/henvalt-shopify-oauth/completion-url.mjs", "utf8");
  assert.match(helper, /if \(!isSafeCompletionDashboardUrl\(configuredBaseUrl\)\) return null/);
});

test("non-production OAuth requires exact explicit ingress and pixel collector host bindings", () => {
  const base = {
    ingressBaseUrl: "https://henvalt-shopify-ingress-staging-no-send.chmuhammadrehan18.workers.dev",
    pixelCollectorUrl: "https://henvalt-pixel-staging.example.workers.dev/v1/events",
    requireExplicitHostBinding: true,
    expectedIngressHost: "henvalt-shopify-ingress-staging-no-send.chmuhammadrehan18.workers.dev",
    expectedPixelCollectorHost: "henvalt-pixel-staging.example.workers.dev",
  };
  assert.equal(resolveOAuthInfrastructure(base).valid, true);
  assert.equal(resolveOAuthInfrastructure({ ...base, expectedIngressHost: "other.example.workers.dev" }).valid, false);
  assert.equal(resolveOAuthInfrastructure({ ...base, expectedPixelCollectorHost: "" }).valid, false);
  assert.equal(resolveOAuthInfrastructure({ ...base, pixelCollectorUrl: "https://production.example.workers.dev/v1/events" }).valid, false);
  assert.equal(resolveOAuthInfrastructure({
    ...base,
    ingressBaseUrl: "https://henvalt-shopify-ingress-staging-no-send.chmuhammadrehan18.workers.dev",
    pixelCollectorUrl: "https://henvalt-pixel-staging.example.workers.dev/v1/events",
    expectedIngressHost: "",
  }).valid, false);
});

test("OAuth derives strict endpoint binding for non-production Supabase deployments", () => {
  const source = readFileSync("supabase/functions/henvalt-shopify-oauth/index.ts", "utf8");
  assert.match(source, /IS_NON_PRODUCTION_SUPABASE/);
  assert.match(source, /requireExplicitHostBinding: IS_NON_PRODUCTION_SUPABASE/);
  assert.match(source, /HENVALT_STAGE_INGRESS_HOST/);
  assert.match(source, /HENVALT_STAGE_PIXEL_COLLECTOR_HOST/);
});

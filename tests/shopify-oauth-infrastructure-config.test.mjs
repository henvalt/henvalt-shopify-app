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

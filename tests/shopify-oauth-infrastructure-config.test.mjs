import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { resolveOAuthInfrastructure } from "../supabase/functions/henvalt-shopify-oauth/infrastructure-config.mjs";

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

test("Shopify app version creation is manual and explicitly opt-in", () => {
  const workflow = readFileSync(".github/workflows/shopify-config-validation.yml", "utf8");
  assert.match(workflow, /workflow_dispatch:/);
  assert.match(workflow, /deploy-shopify-version:\n\s+# Version creation is an explicit operator action/);
  assert.match(workflow, /if: github\.event_name == 'workflow_dispatch' && vars\.HENVALT_ALLOW_SHOPIFY_VERSION_CREATION == 'true'/);
  assert.doesNotMatch(workflow, /if: github\.event_name != 'pull_request'/);
});

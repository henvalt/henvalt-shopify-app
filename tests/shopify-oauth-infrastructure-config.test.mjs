import test from "node:test";
import assert from "node:assert/strict";
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

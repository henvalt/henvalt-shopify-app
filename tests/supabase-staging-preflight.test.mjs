import test from "node:test";
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";

const script = "scripts/supabase-staging-preflight.mjs";
const valid = {
  SUPABASE_URL: "https://xidhtmrfvsgfmyltjuja.supabase.co",
  SHOPIFY_API_KEY: "staging-client-id",
  SHOPIFY_API_SECRET: "staging-secret-placeholder",
  SHOPIFY_REDIRECT_URI: "https://xidhtmrfvsgfmyltjuja.supabase.co/functions/v1/henvalt-shopify-oauth/callback",
  HENVALT_DASHBOARD_URL: "https://henvalt-stage.example.invalid",
  SHOPIFY_WEBHOOK_INGRESS_BASE_URL: "https://henvalt-shopify-ingress-staging-no-send.chmuhammadrehan18.workers.dev",
  SHOPIFY_PIXEL_COLLECTOR_URL: "https://henvalt-pixel-collector-staging-no-send.chmuhammadrehan18.workers.dev/v1/events",
  HENVALT_STAGE_INGRESS_HOST: "henvalt-shopify-ingress-staging-no-send.chmuhammadrehan18.workers.dev",
  HENVALT_STAGE_PIXEL_COLLECTOR_HOST: "henvalt-pixel-collector-staging-no-send.chmuhammadrehan18.workers.dev",
  HENVALT_STAGE_SHOPIFY_STORE: "henvalt-stage.myshopify.com",
  HENVALT_STAGE_NO_SEND: "true",
  HENVALT_STAGE_NETWORK_EGRESS_DENIED: "true",
  HENVALT_STAGE_SHOPIFY_DEV_STORE_CONFIRMED: "true",
  HENVALT_STAGE_VAULT_SHOPIFY_APP_SECRET_PRESENT: "true",
  HENVALT_STAGE_INGRESS_SHARED_SECRET_PRESENT: "true",
  HENVALT_STAGE_PROVIDER_MODE: "stub",
};
const run = (env) => spawnSync(process.execPath, [script], {
  encoding: "utf8",
  env: { ...process.env, ...env },
});

test("accepts exact isolated Supabase OAuth, ingress and pixel configuration in no-send mode", () => {
  const result = run(valid);
  assert.equal(result.status, 0, result.stderr);
  assert.match(result.stdout, /SUPABASE STAGING PREFLIGHT: PASS/);
});

test("rejects production project, callback, dashboard, ingress and pixel hosts", () => {
  const cases = [
    [{ SUPABASE_URL: "https://ocyplckdojdubyrsxcxa.supabase.co" }, /exact isolated HENVALT staging project/],
    [{ SHOPIFY_REDIRECT_URI: "https://ocyplckdojdubyrsxcxa.supabase.co/functions/v1/henvalt-shopify-oauth/callback" }, /exact staging Supabase project/],
    [{ HENVALT_DASHBOARD_URL: "https://app.henvalt.com" }, /must not use a production host/],
    [{ SHOPIFY_WEBHOOK_INGRESS_BASE_URL: "https://henvalt-clean-ingress-v1.chmuhammadrehan18.workers.dev" }, /exact dedicated no-send staging Worker/],
    [{ SHOPIFY_PIXEL_COLLECTOR_URL: "https://henvalt-pixel-collector.chmuhammadrehan18.workers.dev/v1/events" }, /exact dedicated no-send staging Worker/],
  ];
  for (const [override, expected] of cases) {
    const result = run({ ...valid, ...override });
    assert.notEqual(result.status, 0);
    assert.match(result.stderr, expected);
  }
});

test("requires all staging-only no-send and secret-presence confirmations", () => {
  for (const key of [
    "HENVALT_STAGE_NO_SEND",
    "HENVALT_STAGE_NETWORK_EGRESS_DENIED",
    "HENVALT_STAGE_SHOPIFY_DEV_STORE_CONFIRMED",
    "HENVALT_STAGE_VAULT_SHOPIFY_APP_SECRET_PRESENT",
    "HENVALT_STAGE_INGRESS_SHARED_SECRET_PRESENT",
  ]) {
    const result = run({ ...valid, [key]: "false" });
    assert.notEqual(result.status, 0, key);
    assert.match(result.stderr, new RegExp(key + " must be explicitly confirmed true"));
  }
});

test("rejects wrong staging host bindings, live provider mode and non-development store", () => {
  const result = run({
    ...valid,
    HENVALT_STAGE_INGRESS_HOST: "henvalt-clean-ingress-v1.chmuhammadrehan18.workers.dev",
    HENVALT_STAGE_PROVIDER_MODE: "live",
    HENVALT_STAGE_SHOPIFY_STORE: "henvalt.com",
  });
  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /exactly match the no-send staging Worker/);
  assert.match(result.stderr, /must be stub/);
  assert.match(result.stderr, /myshopify.com development store/);
});

test("does not print secret values", () => {
  const secret = "do-not-print-this-shopify-secret";
  const result = run({ ...valid, SHOPIFY_API_SECRET: secret });
  assert.equal(result.status, 0, result.stderr);
  assert.doesNotMatch(result.stdout + result.stderr, new RegExp(secret));
});

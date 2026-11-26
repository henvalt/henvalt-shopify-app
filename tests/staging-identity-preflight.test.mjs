import test from "node:test";
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";

const script = "scripts/staging-identity-preflight.mjs";
const valid = {
  HENVALT_STAGE_SUPABASE_PROJECT_REF: "abcdefghijklmnopqrst",
  HENVALT_STAGE_SHOPIFY_CLIENT_ID: "staging-shopify-client-id",
  HENVALT_STAGE_APPLICATION_URL: "https://staging-dashboard.example.invalid",
  HENVALT_STAGE_DASHBOARD_URL: "https://staging-dashboard.example.invalid",
  HENVALT_STAGE_PRIVACY_WEBHOOK_URL: "https://abcdefghijklmnopqrst.supabase.co/functions/v1/henvalt-shopify-privacy",
  HENVALT_STAGE_N8N_BASE_URL: "https://staging-n8n.example.invalid",
  HENVALT_STAGE_N8N_HOST: "staging-n8n.example.invalid",
  HENVALT_STAGE_INGEST_WORKFLOW_ID: "staging-ingest-1",
  HENVALT_STAGE_RECOVERY_WORKFLOW_ID: "staging-recovery-2",
  HENVALT_STAGE_DELIVERY_WORKFLOW_ID: "staging-delivery-3",
  HENVALT_STAGE_SHOPIFY_STORE: "henvalt-stage.myshopify.com",
  HENVALT_STAGE_SHOPIFY_OAUTH_CALLBACK_URL: "https://abcdefghijklmnopqrst.supabase.co/functions/v1/henvalt-shopify-oauth/callback",
  HENVALT_STAGE_SHOPIFY_WEBHOOK_INGRESS_URL: "https://henvalt-shopify-ingress-staging-no-send.chmuhammadrehan18.workers.dev/shopify/webhooks",
  HENVALT_STAGE_PROVIDER_MODE: "stub",
  HENVALT_STAGE_NETWORK_EGRESS_DENIED: "true",
  HENVALT_STAGE_NO_SEND: "true",
  HENVALT_STAGE_WORKFLOWS_INACTIVE: "true",
  HENVALT_STAGE_SHOPIFY_DEV_STORE_CONFIRMED: "true",
};
const run = (env) => spawnSync(process.execPath, [script], {
  encoding: "utf8",
  env: { ...process.env, ...env },
});

test("staging identity preflight accepts isolated, three-workflow, network-denied no-send metadata", () => {
  const result = run(valid);
  assert.equal(result.status, 0, result.stderr);
  assert.match(result.stdout, /STAGING PREFLIGHT: PASS/);
});

test("preflight rejects production Supabase project identity", () => {
  const result = run({ ...valid, HENVALT_STAGE_SUPABASE_PROJECT_REF: "ocyplckdojdubyrsxcxa" });
  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /matches production/);
});

test("preflight rejects duplicate workflow IDs", () => {
  const result = run({ ...valid, HENVALT_STAGE_DELIVERY_WORKFLOW_ID: valid.HENVALT_STAGE_RECOVERY_WORKFLOW_ID });
  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /three distinct identifiers/);
});

test("preflight rejects each live production workflow ID even when the three IDs are distinct", () => {
  const productionIds = [
    ["HENVALT_STAGE_INGEST_WORKFLOW_ID", "VTpfGKNtu1CSQ4Rv"],
    ["HENVALT_STAGE_RECOVERY_WORKFLOW_ID", "3GEDoeCA4paXTaDF"],
    ["HENVALT_STAGE_DELIVERY_WORKFLOW_ID", "CvVyybGJZSnklxiZ"],
  ];
  for (const [key, id] of productionIds) {
    const result = run({ ...valid, [key]: id });
    assert.notEqual(result.status, 0, key + " must not accept a production workflow ID");
    assert.match(result.stderr, new RegExp(key + " matches a live production workflow ID"));
  }
});

test("preflight rejects missing network-deny proof or no-send flag", () => {
  const result = run({ ...valid, HENVALT_STAGE_NETWORK_EGRESS_DENIED: "false", HENVALT_STAGE_NO_SEND: "false" });
  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /network egress denial/);
  assert.match(result.stderr, /no-send safety flag/);
});

test("preflight rejects live provider mode and production n8n identity", () => {
  const result = run({ ...valid, HENVALT_STAGE_PROVIDER_MODE: "live", HENVALT_STAGE_N8N_BASE_URL: "https://henvalt26.app.n8n.cloud" });
  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /provider mode must be stub/);
  assert.match(result.stderr, /n8n URL matches a production host/);
});

test("preflight rejects incomplete staging inventory", () => {
  const result = run({ ...valid, HENVALT_STAGE_DELIVERY_WORKFLOW_ID: "" });
  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /missing required staging metadata/);
});

test("preflight refuses if imported workflows may be active or store is not confirmed development", () => {
  const result = run({ ...valid, HENVALT_STAGE_WORKFLOWS_INACTIVE: "false", HENVALT_STAGE_SHOPIFY_DEV_STORE_CONFIRMED: "false" });
  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /workflows must be confirmed inactive/);
  assert.match(result.stderr, /development store must be explicitly confirmed/);
});

test("preflight rejects insecure staging n8n URL", () => {
  const result = run({ ...valid, HENVALT_STAGE_N8N_BASE_URL: "http://staging-n8n.example.invalid" });
  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /must be HTTPS/);
});

test("preflight rejects a production Supabase OAuth callback", () => {
  const result = run({ ...valid, HENVALT_STAGE_SHOPIFY_OAUTH_CALLBACK_URL: "https://ocyplckdojdubyrsxcxa.supabase.co/functions/v1/henvalt-shopify-oauth/callback" });
  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /exact staging Supabase project/);
});

test("preflight rejects the live production Cloudflare webhook ingress", () => {
  const result = run({ ...valid, HENVALT_STAGE_SHOPIFY_WEBHOOK_INGRESS_URL: "https://henvalt-clean-ingress-v1.chmuhammadrehan18.workers.dev/shopify/webhooks" });
  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /dedicated no-send staging Worker hostname/);
});

test("preflight rejects custom domains that have not been isolated for staging", () => {
  const result = run({ ...valid, HENVALT_STAGE_SHOPIFY_WEBHOOK_INGRESS_URL: "https://staging.henvalt.com/shopify/webhooks" });
  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /dedicated no-send staging Worker hostname/);
});

test("preflight rejects malformed or insecure Shopify staging endpoints", () => {
  const callback = run({ ...valid, HENVALT_STAGE_SHOPIFY_OAUTH_CALLBACK_URL: "http://abcdefghijklmnopqrst.supabase.co/functions/v1/henvalt-shopify-oauth/callback" });
  assert.notEqual(callback.status, 0);
  assert.match(callback.stderr, /exact staging Supabase project/);
  const ingress = run({ ...valid, HENVALT_STAGE_SHOPIFY_WEBHOOK_INGRESS_URL: "http://staging-ingress.example.invalid/shopify/webhooks" });
  assert.notEqual(ingress.status, 0);
  assert.match(ingress.stderr, /HTTPS \/shopify\/webhooks URL/);
});

test("preflight requires an isolated OAuth completion dashboard matching the staging application", () => {
  const missing = run({ ...valid, HENVALT_STAGE_DASHBOARD_URL: "" });
  assert.notEqual(missing.status, 0);
  assert.match(missing.stderr, /missing required staging metadata: HENVALT_STAGE_DASHBOARD_URL/);
  const production = run({ ...valid, HENVALT_STAGE_DASHBOARD_URL: "https://henvalt-dashboard.pages.dev" });
  assert.notEqual(production.status, 0);
  assert.match(production.stderr, /matches a production host/);
  const mismatched = run({ ...valid, HENVALT_STAGE_DASHBOARD_URL: "https://other-stage.example.invalid" });
  assert.notEqual(mismatched.status, 0);
  assert.match(mismatched.stderr, /match the isolated staging application origin/);
});

test("preflight requires an exact staging n8n host allowlist", () => {
  const missing = run({ ...valid, HENVALT_STAGE_N8N_HOST: "" });
  assert.notEqual(missing.status, 0);
  assert.match(missing.stderr, /missing required staging metadata: HENVALT_STAGE_N8N_HOST/);
  const mismatch = run({ ...valid, HENVALT_STAGE_N8N_HOST: "other-staging-n8n.example.invalid" });
  assert.notEqual(mismatch.status, 0);
  assert.match(mismatch.stderr, /exactly match the explicit staging n8n host allowlist/);
  const production = run({ ...valid, HENVALT_STAGE_N8N_BASE_URL: "https://n8n.henvalt.com", HENVALT_STAGE_N8N_HOST: "n8n.henvalt.com" });
  assert.notEqual(production.status, 0);
  assert.match(production.stderr, /matches a production host/);
  const labelledProduction = run({ ...valid, HENVALT_STAGE_N8N_BASE_URL: "https://prod-stage.example.invalid", HENVALT_STAGE_N8N_HOST: "prod-stage.example.invalid" });
  assert.notEqual(labelledProduction.status, 0);
  assert.match(labelledProduction.stderr, /host appears to identify production/);
});

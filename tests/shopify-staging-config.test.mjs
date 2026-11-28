import test from "node:test";
import assert from "node:assert/strict";\nimport { readFileSync } from "node:fs";
import { renderShopifyStagingConfig } from "../scripts/render-shopify-staging-config.mjs";

const valid = {
  HENVALT_STAGE_SHOPIFY_CLIENT_ID: "staging-shopify-client-id",
  HENVALT_STAGE_SUPABASE_PROJECT_REF: "abcdefghijklmnopqrst",
  HENVALT_STAGE_APPLICATION_URL: "https://staging-dashboard.example.test/",
  HENVALT_STAGE_PRIVACY_WEBHOOK_URL: "https://abcdefghijklmnopqrst.supabase.co/functions/v1/henvalt-shopify-privacy",
};

test("staging Shopify config refuses missing identity values", () => {
  assert.throws(() => renderShopifyStagingConfig({}), /missing required staging value/);
});

test("staging Shopify config refuses production client and Supabase identities", () => {
  assert.throws(() => renderShopifyStagingConfig({
    ...valid,
    HENVALT_STAGE_SHOPIFY_CLIENT_ID: "1c0fd15c032fa26cd15ad7a63577a506",
  }), /matches production/);
  assert.throws(() => renderShopifyStagingConfig({
    ...valid,
    HENVALT_STAGE_SUPABASE_PROJECT_REF: "ocyplckdojdubyrsxcxa",
    HENVALT_STAGE_PRIVACY_WEBHOOK_URL: "https://ocyplckdojdubyrsxcxa.supabase.co/functions/v1/henvalt-shopify-privacy",
  }), /invalid or matches production/);
});

test("staging Shopify config uses only the staging callback and privacy endpoint", () => {
  const config = renderShopifyStagingConfig(valid);
  assert.match(config, /name = "HENVALT Staging"/);
  assert.match(config, /https:\/\/abcdefghijklmnopqrst\.supabase\.co\/functions\/v1\/henvalt-shopify-oauth\/callback/);
  assert.match(config, /https:\/\/abcdefghijklmnopqrst\.supabase\.co\/functions\/v1\/henvalt-shopify-privacy/);
  assert.doesNotMatch(config, /ocyplckdojdubyrsxcxa/);
  assert.doesNotMatch(config, /henvalt-dashboard\.pages\.dev/);
  assert.doesNotMatch(config, /SHOPIFY_API_SECRET|SERVICE_ROLE|MAILERSEND_API_KEY/);
});

test("staging Shopify config rejects all known production application hosts", () => {
  for (const host of ["henvalt-dashboard.pages.dev", "henvalt.com", "app.henvalt.com", "n8n.henvalt.com"]) {
    assert.throws(() => renderShopifyStagingConfig({
      ...valid,
      HENVALT_STAGE_APPLICATION_URL: "https://" + host,
    }), /matches production dashboard/);
  }
});

test("staging Shopify config rejects production dashboard and mismatched privacy project", () => {
  assert.throws(() => renderShopifyStagingConfig({
    ...valid,
    HENVALT_STAGE_APPLICATION_URL: "https://henvalt-dashboard.pages.dev",
  }), /matches production dashboard/);
  assert.throws(() => renderShopifyStagingConfig({
    ...valid,
    HENVALT_STAGE_PRIVACY_WEBHOOK_URL: "https://ocyplckdojdubyrsxcxa.supabase.co/functions/v1/henvalt-shopify-privacy",
  }), /exact staging Supabase project/);
});

test("checked-in staging Shopify app config binds the exact verified staging app and endpoints", () => {
  const config = readFileSync(new URL("../shopify.app.staging.toml", import.meta.url), "utf8");
  const oauth = readFileSync(new URL("../supabase/functions/henvalt-shopify-oauth/index.ts", import.meta.url), "utf8");
  assert.match(config, /client_id = "18867683f4dce4d63179a83e84447e5b"/);
  assert.match(config, /application_url = "https:\/\/65003dc3\.henvalt-dashboard-preview\.pages\.dev"/);
  assert.match(config, /xidhtmrfvsgfmyltjuja\.supabase\.co\/functions\/v1\/henvalt-shopify-oauth\/callback/);
  assert.match(config, /xidhtmrfvsgfmyltjuja\.supabase\.co\/functions\/v1\/henvalt-shopify-privacy/);
  assert.doesNotMatch(config, /ocyplckdojdubyrsxcxa|henvalt-dashboard\.pages\.dev/);
  assert.match(oauth, /STAGING_DASHBOARD_URL = "https:\/\/65003dc3\.henvalt-dashboard-preview\.pages\.dev"/);
  assert.match(oauth, /STAGING_INGRESS_BASE_URL/);
  assert.match(oauth, /STAGING_PIXEL_COLLECTOR_URL/);
});

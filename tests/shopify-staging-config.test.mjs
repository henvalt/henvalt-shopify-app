import test from "node:test";
import assert from "node:assert/strict";
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

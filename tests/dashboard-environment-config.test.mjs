import test from "node:test";
import assert from "node:assert/strict";
import { resolveDashboardConfig, onRequest } from "../dashboard/functions/config.js";

const stageHost = "work-48h-system-readiness-20.henvalt-dashboard-preview.pages.dev";
const stageEnv = {
  HENVALT_STAGE_NO_SEND: "true",
  HENVALT_STAGE_SUPABASE_PROJECT_REF: "abcdefghijklmnopqrst",
  HENVALT_STAGE_SUPABASE_URL: "https://abcdefghijklmnopqrst.supabase.co",
  HENVALT_STAGE_SUPABASE_PUBLISHABLE_KEY: "sb_publishable_staging_test_key",
};

test("production dashboard host retains its existing production configuration", () => {
  const config = resolveDashboardConfig("henvalt-dashboard.pages.dev", {});
  assert.equal(config.environment, "production");
  assert.equal(config.noSend, false);
  assert.equal(config.supabaseUrl, "https://ocyplckdojdubyrsxcxa.supabase.co");
});

test("Pages preview is disabled unless explicit no-send staging environment variables exist", () => {
  assert.equal(resolveDashboardConfig(stageHost, {}), null);
  assert.equal(resolveDashboardConfig(stageHost, { ...stageEnv, HENVALT_STAGE_NO_SEND: "false" }), null);
});

test("Pages preview receives only the isolated staging Supabase project and endpoints", () => {
  const config = resolveDashboardConfig(stageHost, stageEnv);
  assert.equal(config.environment, "staging");
  assert.equal(config.noSend, true);
  assert.equal(config.supabaseUrl, stageEnv.HENVALT_STAGE_SUPABASE_URL);
  assert.equal(config.setup, null);
  assert.match(config.api, /^https:\/\/abcdefghijklmnopqrst\.supabase\.co\/functions\/v1\//);
  assert.match(config.shopifyOAuth, /henvalt-shopify-oauth\/auth$/);
  assert.doesNotMatch(JSON.stringify(config), /ocyplckdojdubyrsxcxa/);
});

test("Pages preview refuses production project identity, mismatched URL and non-publishable key", () => {
  assert.equal(resolveDashboardConfig(stageHost, {
    ...stageEnv,
    HENVALT_STAGE_SUPABASE_PROJECT_REF: "ocyplckdojdubyrsxcxa",
    HENVALT_STAGE_SUPABASE_URL: "https://ocyplckdojdubyrsxcxa.supabase.co",
  }), null);
  assert.equal(resolveDashboardConfig(stageHost, {
    ...stageEnv,
    HENVALT_STAGE_SUPABASE_URL: "https://another-project.supabase.co",
  }), null);
  assert.equal(resolveDashboardConfig(stageHost, {
    ...stageEnv,
    HENVALT_STAGE_SUPABASE_PUBLISHABLE_KEY: "service_role_secret",
  }), null);
});

test("unknown hostnames never receive production or staging backend configuration", () => {
  assert.equal(resolveDashboardConfig("random-preview.pages.dev", {}), null);
});

test("Pages config endpoint returns no-store JS and fails closed when staging env is absent", async () => {
  const response = await onRequest({
    request: new Request("https://" + stageHost + "/config"),
    env: {},
  });
  assert.equal(response.status, 503);
  assert.match(response.headers.get("content-type"), /application\/javascript/);
  assert.match(await response.text(), /window\.HENVALT_CONFIG = null/);
});

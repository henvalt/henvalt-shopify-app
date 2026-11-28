import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
const source = readFileSync(new URL("../dashboard/functions/config.js", import.meta.url), "utf8");
const moduleUrl = "data:text/javascript;base64," + Buffer.from(source).toString("base64");
const { resolveDashboardConfig, onRequest } = await import(moduleUrl);

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
  assert.equal(config.shopifyOAuth, null);
  assert.equal(config.billingReconciliation, null);
  assert.equal(config.privacyExport, null);
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

test("dashboard HTML consumes environment-scoped config and blocks no-send provider actions", () => {
  const html = readFileSync(new URL("../dashboard/index.html", import.meta.url), "utf8");
  assert.match(html, /<script src="\/config"><\/script>/);
  assert.match(html, /window\.HENVALT_CONFIG/);
  assert.match(html, /CONFIG\.noSend\|\|!SETUP/);
  assert.match(html, /Billing reconciliation decisions are disabled in no-send staging/);
  assert.match(html, /fetch\(SHOPIFY_OAUTH/);
  assert.match(html, /STAGING · NO SEND · SHOPIFY OAUTH, PROVIDER SETUP, PRIVACY EXPORT AND BILLING ACTIONS DISABLED/);
  assert.doesNotMatch(html, /const PRIVACY_EXPORT="https:\/\/ocyplckdojdubyrsxcxa/);
});

import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const source = readFileSync("dashboard/index.html", "utf8");
const configSource = readFileSync("dashboard/functions/config.js", "utf8");

test("dashboard loads a runtime config endpoint before application code", () => {
  const configScript = source.indexOf('<script src="/config"></script>');
  const appScript = source.indexOf("<script>\nconst PRODUCTION_FALLBACK");
  assert.ok(configScript >= 0, "runtime config endpoint must be loaded");
  assert.ok(appScript > configScript, "runtime config must load before application initialization");
});

test("only the exact production Pages hostname can fall back to production constants", () => {
  assert.match(source, /location\.hostname === "henvalt-dashboard\.pages\.dev" \? PRODUCTION_FALLBACK : null/);
  assert.match(source, /const CONFIG = window\.HENVALT_CONFIG/);
  assert.match(source, /DASHBOARD_ENVIRONMENT_CONFIG_MISSING/);
  assert.match(source, /https:\/\/ocyplckdojdubyrsxcxa\.supabase\.co/);
});

test("preview without a verified staging config exits before Supabase client creation", () => {
  const scripts = [...source.matchAll(/<script>\s*([\s\S]*?)<\/script>/g)];
  assert.ok(scripts.length > 0, "inline dashboard application script must exist");
  const appScript = scripts[scripts.length - 1][1];
  let rendered = "";
  let clientInitializations = 0;
  const document = {
    body: {
      set innerHTML(value) { rendered = String(value); },
      prepend() {},
    },
  };
  const supabase = {
    createClient() {
      clientInitializations += 1;
      throw new Error("Supabase client must not initialize on an unconfigured preview");
    },
  };
  assert.throws(
    () => new Function("window", "location", "document", "supabase", appScript)(
      { HENVALT_CONFIG: null },
      { hostname: "work-48h-system-readiness-20.henvalt-dashboard-preview.pages.dev" },
      document,
      supabase,
    ),
    /DASHBOARD_ENVIRONMENT_CONFIG_MISSING/,
  );
  assert.equal(clientInitializations, 0);
  assert.match(rendered, /Preview environment/);
  assert.match(rendered, /no verified staging backend/);
});

test("no-send dashboard disables provider setup and billing-resolution writes", () => {
  assert.match(source, /if\(CONFIG\.noSend\|\|!SETUP\)/);
  assert.match(source, /Billing reconciliation decisions are disabled in no-send staging/);
  assert.match(source, /Provider setup is disabled in no-send staging/);
  assert.match(source, /STAGING · NO SEND · SHOPIFY OAUTH TESTING ALLOWED · EMAIL, PROVIDER SETUP AND BILLING LOCKED/);
});


test("staging config exposes dashboard and isolated OAuth endpoints while keeping money paths disabled", () => {
  const staging = configSource.slice(configSource.indexOf('environment: "staging"'));
  assert.match(staging, /noSend: true/);
  assert.match(staging, /api:.*henvalt-merchant-dashboard/);
  assert.match(staging, /billingReconciliation: null/);
  assert.match(staging, /privacyExport: `\$\{functions\}\/henvalt-privacy-export`/);
  assert.match(staging, /shopifyOAuth: `\$\{functions\}\/henvalt-shopify-oauth\/auth`/);
});

test("no-send preview exposes privacy export but keeps billing and provider paths disabled", () => {
  assert.match(source, /Privacy export is not deployed in staging/);
  assert.match(source, /Billing reconciliation is not deployed in staging/);
  assert.match(source, /Staging OAuth test only · email and billing remain disabled/);
  assert.match(source, /if\(!SHOPIFY_OAUTH\)/);
  assert.doesNotMatch(source, /if\(CONFIG\.noSend\|\|!SHOPIFY_OAUTH\)/);
  assert.match(configSource, /privacyExport: `\$\{functions\}\/henvalt-privacy-export`/);
  assert.doesNotMatch(configSource.slice(configSource.indexOf('environment: "staging"')), /privacyExport: null/);
  assert.match(source, /SHOPIFY OAUTH TESTING ALLOWED · EMAIL, PROVIDER SETUP AND BILLING LOCKED/);
});

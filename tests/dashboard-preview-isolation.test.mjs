import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const source = readFileSync("dashboard/index.html", "utf8");

test("branch preview exits before production Supabase client or API initialization", () => {
  const guard = 'if(location.hostname!=="henvalt-dashboard.pages.dev")';
  const guardAt = source.indexOf(guard);
  const apiAt = source.indexOf('const BILLING_RECONCILIATION="https://ocyplckdojdubyrsxcxa.supabase.co/functions/v1/henvalt-billing-reconciliation"');
  const clientAt = source.indexOf("supabase.createClient(SUPABASE_URL,SUPABASE_KEY");
  assert.ok(guardAt >= 0, "preview host allowlist must be explicit");
  assert.ok(apiAt > guardAt, "production API endpoints must be declared after the preview guard");
  assert.ok(clientAt > guardAt, "production Supabase client must initialize only after the preview guard");
  assert.match(source.slice(guardAt, apiAt), /PREVIEW_BUILD_LIVE_API_DISABLED/);
  assert.match(source.slice(guardAt, apiAt), /document\.body\.innerHTML/);
});

test("only the verified production Pages hostname can run live dashboard operations", () => {
  assert.match(source, /location\.hostname!==["']henvalt-dashboard\.pages\.dev["']/);
  assert.match(source, /Shopify authorization, billing, provider setup and customer data are disabled here/);
  assert.match(source, /https:\/\/ocyplckdojdubyrsxcxa\.supabase\.co\/functions\/v1\/henvalt-merchant-dashboard/);
  assert.match(source, /https:\/\/ocyplckdojdubyrsxcxa\.supabase\.co\/functions\/v1\/henvalt-billing-reconciliation/);
});

test("preview guard executes before Supabase client creation and all application handlers", () => {
  const scripts = [...source.matchAll(/<script>\\s*([\\s\\S]*?)<\\/script>/g)];
  assert.ok(scripts.length > 0, "inline dashboard application script must exist");
  const appScript = scripts[scripts.length - 1][1];
  let rendered = "";
  let clientInitializations = 0;
  const document = {
    body: {
      set innerHTML(value) { rendered = String(value); },
    },
  };
  const supabase = {
    createClient() {
      clientInitializations += 1;
      throw new Error("production client must not initialize on preview");
    },
  };
  assert.throws(
    () => new Function("location", "document", "supabase", appScript)(
      { hostname: "work-48h-system-readiness-20.henvalt-dashboard-preview.pages.dev" },
      document,
      supabase,
    ),
    /PREVIEW_BUILD_LIVE_API_DISABLED/,
  );
  assert.equal(clientInitializations, 0);
  assert.match(rendered, /Preview environment/);
  assert.match(rendered, /customer data are disabled here/);
});

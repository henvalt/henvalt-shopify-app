import test from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";

const html = await readFile(new URL("../dashboard/index.html", import.meta.url), "utf8");

test("dashboard exposes a dedicated billing review page without a service-role credential", () => {
  assert.match(html, /data-page="billing"/);
  assert.match(html, /id="page-billing"/);
  assert.match(html, /BILLING_RECONCILIATION="https:\/\/ocyplckdojdubyrsxcxa\.supabase\.co\/functions\/v1\/henvalt-billing-reconciliation"/);
  assert.doesNotMatch(html, /SUPABASE_SERVICE_ROLE_KEY/);
});

test("billing review reads queue and charge envelope through the authenticated Edge Function", () => {
  assert.match(html, /async function loadBillingCases\(\)/);
  assert.match(html, /control_plane_list_billing_reconciliations/ === false/); // browser must not call database RPCs directly
  assert.match(html, /BILLING_RECONCILIATION\+\?"\?chargeId="/);
  assert.match(html, /Authorization:"Bearer "\+session\.access_token/);
});

test("billing decisions require operator note and evidence and are submitted through the server endpoint", () => {
  assert.match(html, /async function resolveBillingCase\(e\)/);
  assert.match(html, /JSON\.parse\(\$\("billingevidence"\)\.value\)/);
  assert.match(html, /action:"resolve",chargeId,resolution,providerUsageRecordId,evidence,operatorNote:/);
  assert.match(html, /independently complete the Shopify Admin GraphQL lookup/);
  assert.match(html, /Every decision is attributed to your authenticated HENVALT account/);
});

test("billing review is wired into navigation and escapes untrusted case fields", () => {
  assert.match(html, /if\(page==="billing"\)loadBillingCases\(\)/);
  assert.match(html, /esc\(r\.reason\|\|"—"\)/);
  assert.match(html, /esc\(v\?\?"—"\)/);
});

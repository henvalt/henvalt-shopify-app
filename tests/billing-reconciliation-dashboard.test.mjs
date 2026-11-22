import test from "node:test";
import assert from "node:assert/strict";
import vm from "node:vm";
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
  assert.doesNotMatch(html, /control_plane_list_billing_reconciliations/);
  assert.match(html, /BILLING_RECONCILIATION\+?"\?chargeId="/);
  assert.match(html, /Authorization:"Bearer "\+session\.access_token/);
});

test("billing decisions cannot submit browser-created provider evidence", () => {
  assert.match(html, /async function resolveBillingCase\(e\)/);
  assert.doesNotMatch(html, /billingevidence|billingproviderid/);
  assert.match(html, /action:"resolve",chargeId,resolution,operatorNote:/);
  assert.match(html, /retrieves the stored Shopify access token server-side/);
  assert.match(html, /Every decision is attributed to your authenticated HENVALT account/);
});

test("dashboard inline JavaScript parses after adding the reconciliation panel", () => {
  const scripts = [...html.matchAll(/<script(?:\s[^>]*)?>([\s\S]*?)<\/script>/g)]
    .map((match) => match[1])
    .filter((source) => source.includes("async function init()"));
  assert.equal(scripts.length, 1);
  assert.doesNotThrow(() => new vm.Script(scripts[0], { filename: "dashboard/index.html" }));
});

test("billing review is wired into navigation and escapes untrusted case fields", () => {
  assert.match(html, /if\(page==="billing"\)loadBillingCases\(\)/);
  assert.match(html, /esc\(r\.reason\|\|"—"\)/);
  assert.match(html, /esc\(v\?\?"—"\)/);
});

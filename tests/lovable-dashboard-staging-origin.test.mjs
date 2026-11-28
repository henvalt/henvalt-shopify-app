import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const lovablePreview = "https://id-preview--6382eaeb-7d73-473e-810b-2b89184d4bf0.lovable.app";
const oauth = readFileSync("supabase/functions/henvalt-shopify-oauth/index.ts", "utf8");
const privacy = readFileSync("supabase/functions/henvalt-privacy-export/index.ts", "utf8");

test("staging Shopify OAuth returns to the existing Lovable dashboard preview", () => {
  assert.ok(oauth.includes(`const STAGING_DASHBOARD_URL = "${lovablePreview}";`));
  assert.doesNotMatch(oauth, /65003dc3\.henvalt-dashboard-preview\.pages\.dev/);
});

test("staging privacy export CORS allows the same Lovable dashboard origin", () => {
  assert.ok(privacy.includes(`const STAGING_DASHBOARD_ORIGIN = "${lovablePreview}";`));
  assert.doesNotMatch(privacy, /65003dc3\.henvalt-dashboard-preview\.pages\.dev/);
  assert.match(privacy, /PRODUCTION_DASHBOARD_ORIGIN = "https:\/\/henvalt-dashboard\.pages\.dev"/);
});

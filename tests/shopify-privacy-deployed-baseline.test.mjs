import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const privacy = readFileSync("supabase/audit-baselines/henvalt-shopify-privacy-v1.ts", "utf8");
const exportEndpoint = readFileSync("supabase/audit-baselines/henvalt-privacy-export-v1.ts", "utf8");
const blocker = readFileSync("docs/SHOPIFY_PRIVACY_COMPLIANCE_BLOCKER_2026-11-21.md", "utf8");

test("deployed privacy handler v1 is pinned as an audit baseline, not represented as remediated", () => {
  assert.match(privacy, /AUDIT BASELINE ONLY/);
  assert.match(privacy, /213af659378fd3da90b8edbfce12347445e4f5ce633ca6bf6705f8d3cae3e5f4/);
  assert.match(privacy, /x-shopify-shop-id/);
  assert.doesNotMatch(privacy, /payload\.shop_id\s*!==?\s*row\.shopify_shop_id/);
  assert.match(privacy, /shopify_privacy_requests\?select=id,status/);
  assert.doesNotMatch(privacy, /status:\s*"PROCESSING"/);
  assert.match(privacy, /status:\s*"REVIEW_REQUIRED"/);
  assert.match(blocker, /identity binding/i);
  assert.match(blocker, /atomic claim\/lease/i);
});

test("customer redaction baseline exposes the ineffective no-match branch for follow-up", () => {
  assert.match(privacy, /if \(!result\?\.matched\)/);
  assert.match(privacy, /customer_record_not_found/);
  assert.match(blocker, /returns `matched: true` unconditionally/);
});

test("separate privacy export endpoint is owner-authenticated pull delivery, not automatic dispatch", () => {
  assert.match(exportEndpoint, /AUDIT BASELINE ONLY/);
  assert.match(exportEndpoint, /708f0d953874f9e4896f433d950d57b823b56cbb33e30e8c0b1f966ec1212d97/);
  assert.match(exportEndpoint, /auth\/v1\/user/);
  assert.match(exportEndpoint, /role=in\.\(OWNER,ADMIN\)/);
  assert.match(exportEndpoint, /result_delivered_at/);
  assert.match(exportEndpoint, /content-disposition/);
  assert.doesNotMatch(exportEndpoint, /fetch\([^\n]*mailer|sendgrid|mailersend/i);
  assert.match(blocker, /merchant-owner pull\/download endpoint/i);
  assert.match(blocker, /before the response body has been confirmed received/i);
});

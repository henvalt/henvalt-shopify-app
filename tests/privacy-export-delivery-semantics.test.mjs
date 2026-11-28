import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const baseline = readFileSync("supabase/audit-baselines/henvalt-privacy-export-v1.ts", "utf8");
const candidate = readFileSync("supabase/functions/henvalt-privacy-export/index.ts", "utf8");
const audit = readFileSync("docs/PRIVACY_EXPORT_DELIVERY_SEMANTICS_2026-11-22.md", "utf8");

test("deployed export source remains an immutable audit baseline", () => {
  assert.match(baseline, /AUDIT BASELINE ONLY/);
  assert.match(baseline, /Source SHA-256:/);
});

test("audit documents that result_delivered_at is written before response construction", () => {
  const mark = baseline.indexOf("result_delivered_at: new Date().toISOString()");
  const response = baseline.indexOf("return new Response(JSON.stringify(record.result_payload, null, 2)");
  assert.ok(mark >= 0 && response > mark, "baseline ordering changed; re-audit before changing the finding");
  assert.match(audit, /cannot prove that the merchant's browser received/);
  assert.match(audit, /response-start event/);
  assert.match(audit, /Production remains NO-GO/);
});

test("candidate export endpoint separates download start from client acknowledgement", () => {
  assert.match(candidate, /result_download_started_at/);
  assert.match(candidate, /x-henvalt-delivery-ack-token/);
  assert.match(candidate, /rpc\/acknowledge_shopify_privacy_export_download/);
  assert.doesNotMatch(candidate, /result_delivered_at:\\s*new Date/);
  assert.ok(candidate.indexOf("result_download_started_at") < candidate.indexOf("return new Response(JSON.stringify(record.result_payload, null, 2)"));
});

test("candidate export endpoint binds CORS to the isolated staging or production dashboard", () => {
  assert.match(candidate, /STAGING_SUPABASE_URL = "https:\/\/xidhtmrfvsgfmyltjuja\.supabase\.co"/);
  assert.match(candidate, /STAGING_DASHBOARD_ORIGIN = "https:\/\/id-preview--6382eaeb-7d73-473e-810b-2b89184d4bf0\.lovable\.app"/);
  assert.match(candidate, /PRODUCTION_DASHBOARD_ORIGIN = "https:\/\/henvalt-dashboard\.pages\.dev"/);
  assert.match(candidate, /const DASHBOARD_ORIGIN = NORMALIZED_SUPABASE_URL === STAGING_SUPABASE_URL/);
  assert.match(candidate, /IS_STAGING && Deno\.env\.get\("HENVALT_STAGE_NO_SEND"\) !== "true"/);
});

import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const baseline = readFileSync("supabase/functions/henvalt-privacy-export/index.ts", "utf8");
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

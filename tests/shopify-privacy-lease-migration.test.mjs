import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const sql = readFileSync("supabase/migrations/202611220001_shopify_privacy_claim_and_minimization.sql", "utf8");

test("privacy request claims are serialized and lease bounded", () => {
  assert.match(sql, /for update skip locked/i);
  assert.match(sql, /lease_token\s*=\s*v_token/i);
  assert.match(sql, /lease_expires_at\s*=\s*now\(\)\s*\+/i);
  assert.match(sql, /p_lease_seconds < 15 or p_lease_seconds > 300/i);
});

test("privacy request completion is fenced by the live lease", () => {
  assert.match(sql, /r\.lease_token\s*=\s*p_lease_token/i);
  assert.match(sql, /r\.lease_expires_at > now\(\)/i);
  assert.match(sql, /r\.status = 'PROCESSING'/i);
});

test("terminal privacy outcomes minimize inbound personal data", () => {
  assert.match(sql, /payload = '\{\}'::jsonb/i);
  assert.match(sql, /customer_id = null/i);
  assert.match(sql, /revoke all on function henvalt\.claim_shopify_privacy_request/i);
  assert.match(sql, /to service_role/i);
});

test("shared PostgreSQL acceptance suites run before the privacy fixture resets henvalt", () => {
  const workflow = readFileSync(".github/workflows/provider-send-interlock-static.yml", "utf8");
  const privacyBootstrap = readFileSync("tests/shopify-privacy-lease-postgres-bootstrap.sql", "utf8");
  const providerStep = workflow.indexOf("name: Exercise deny, allow, audit, consent and fail-closed paths");
  const privacyResetStep = workflow.indexOf("name: Bootstrap isolated Shopify privacy lease fixture");
  assert.notEqual(providerStep, -1, "provider acceptance step must exist");
  assert.notEqual(privacyResetStep, -1, "privacy fixture bootstrap step must exist");
  assert.ok(providerStep < privacyResetStep, "provider acceptance must run before the privacy fixture drops/recreates henvalt");
  assert.match(privacyBootstrap, /drop schema if exists henvalt cascade/i);
});


test("handler-facing claim RPC is scoped to the exact inserted request", () => {
  assert.match(sql, /function henvalt\.claim_shopify_privacy_request_by_id/i);
  assert.match(sql, /r\.id = p_request_id/i);
  assert.match(sql, /grant execute on function henvalt\.claim_shopify_privacy_request_by_id\(uuid, integer\) to service_role/i);
});

test("retryable failures retain only bounded retry identifiers and exhaust to review", () => {
  assert.match(sql, /r\.lease_attempts < 8/i);
  assert.match(sql, /p_status = 'FAILED' and r\.lease_attempts >= 8/i);
  assert.match(sql, /then 'REVIEW_REQUIRED'/i);
  assert.match(sql, /then null else r\.customer_id/i);
  assert.match(sql, /then '\{\}'::jsonb else r\.payload/i);
});

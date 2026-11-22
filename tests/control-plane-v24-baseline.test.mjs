import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const source = readFileSync(new URL("../supabase/audit-baselines/henvalt-control-plane-v24.ts", import.meta.url), "utf8");
const metadata = JSON.parse(readFileSync(new URL("../supabase/audit-baselines/henvalt-control-plane-v24.json", import.meta.url), "utf8"));

test("captured production control-plane baseline is pinned to the inspected deployment", () => {
  assert.equal(metadata.function_slug, "henvalt-control-plane");
  assert.equal(metadata.deployed_version, 24);
  assert.equal(metadata.deployed_status, "ACTIVE");
  assert.equal(metadata.verify_jwt, false);
  assert.match(metadata.deployment_artifact_ezbr_sha256, /^[a-f0-9]{64}$/);
  assert.ok(metadata.evidence_limits.some((item) => /complete set of external callers/i.test(item)));
});

test("the deployed handler has a custom bearer-token boundary despite gateway JWT being disabled", () => {
  assert.match(source, /authorization\.startsWith\("Bearer "\)/);
  assert.match(source, /control_plane_verify_api_token/);
  assert.match(source, /x-henvalt-shop/);
  assert.equal(metadata.auth_boundary.vault_secret_name, "HENVALT_CONTROL_PLANE_TOKEN");
  assert.equal(/(?:SUPABASE_SERVICE_ROLE_KEY|HENVALT_CONTROL_PLANE_TOKEN)\s*=\s*["'][^"']+["']/.test(source), false);
});

test("both legacy usage billing routes and their RPC dependencies are present in the deployed baseline", () => {
  assert.match(source, /path === "\/v1\/billing\/usage\/claim"/);
  assert.match(source, /control_plane_claim_billing_usage/);
  assert.match(source, /path === "\/v1\/billing\/usage\/result"/);
  assert.match(source, /control_plane_record_billing_usage_result/);
  assert.match(source, /p_success: success/);
});

test("Shopify webhook proxy is captured for caller inventory before ingress retirement", () => {
  assert.match(source, /path === "\/v1\/webhooks\/shopify"/);
  assert.match(source, /N8N_INGEST_URL/);
  assert.match(source, /x-shopify-hmac-sha256/);
  assert.match(source, /fetch\(N8N_INGEST_URL/);
  assert.ok(metadata.evidence_limits.some((item) => /external caller/i.test(item)));
});

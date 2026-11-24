import test from "node:test";
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";

const script = "scripts/staging-identity-preflight.mjs";
const valid = {
  HENVALT_STAGE_SUPABASE_PROJECT_REF: "staging-project-ref-123",
  HENVALT_STAGE_N8N_BASE_URL: "https://staging-n8n.example.invalid",
  HENVALT_STAGE_INGEST_WORKFLOW_ID: "staging-ingest-1",
  HENVALT_STAGE_RECOVERY_WORKFLOW_ID: "staging-recovery-2",
  HENVALT_STAGE_DELIVERY_WORKFLOW_ID: "staging-delivery-3",
  HENVALT_STAGE_SHOPIFY_STORE: "henvalt-stage.myshopify.com",
  HENVALT_STAGE_PROVIDER_MODE: "stub",
  HENVALT_STAGE_NETWORK_EGRESS_DENIED: "true",
  HENVALT_STAGE_NO_SEND: "true",
};
const run = (env) => spawnSync(process.execPath, [script], {
  encoding: "utf8",
  env: { ...process.env, ...env },
});

test("staging identity preflight accepts isolated, three-workflow, network-denied no-send metadata", () => {
  const result = run(valid);
  assert.equal(result.status, 0, result.stderr);
  assert.match(result.stdout, /STAGING PREFLIGHT: PASS/);
});

test("preflight rejects production Supabase project identity", () => {
  const result = run({ ...valid, HENVALT_STAGE_SUPABASE_PROJECT_REF: "ocyplckdojdubyrsxcxa" });
  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /matches production/);
});

test("preflight rejects duplicate workflow IDs", () => {
  const result = run({ ...valid, HENVALT_STAGE_DELIVERY_WORKFLOW_ID: valid.HENVALT_STAGE_RECOVERY_WORKFLOW_ID });
  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /three distinct identifiers/);
});

test("preflight rejects missing network-deny proof or no-send flag", () => {
  const result = run({ ...valid, HENVALT_STAGE_NETWORK_EGRESS_DENIED: "false", HENVALT_STAGE_NO_SEND: "false" });
  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /network egress denial/);
  assert.match(result.stderr, /no-send safety flag/);
});

test("preflight rejects live provider mode and production n8n identity", () => {
  const result = run({ ...valid, HENVALT_STAGE_PROVIDER_MODE: "live", HENVALT_STAGE_N8N_BASE_URL: "https://henvalt26.app.n8n.cloud" });
  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /provider mode must be stub/);
  assert.match(result.stderr, /n8n URL appears to identify production/);
});

test("preflight rejects incomplete staging inventory", () => {
  const result = run({ ...valid, HENVALT_STAGE_DELIVERY_WORKFLOW_ID: "" });
  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /missing required staging metadata/);
});

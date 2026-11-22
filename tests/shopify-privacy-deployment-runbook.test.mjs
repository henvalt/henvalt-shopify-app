import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const runbook = readFileSync("docs/SHOPIFY_PRIVACY_DEPLOYMENT_RUNBOOK_2026-11-22.md", "utf8");

test("privacy runbook applies only the five ordered candidate migrations", () => {
  const migrations = [
    "202611220001_shopify_privacy_claim_and_minimization.sql",
    "202611220002_shopify_privacy_redaction_guards.sql",
    "202611220003_shopify_privacy_retention_cron.sql",
    "202611220004_shopify_privacy_signed_payload_idempotency.sql",
    "202611220005_shopify_privacy_queue_worker.sql",
  ];
  let last = -1;
  for (const migration of migrations) {
    const next = runbook.indexOf(migration);
    assert.ok(next > last, "Migration order missing or invalid: " + migration);
    last = next;
  }
  assert.match(runbook, /Do not run an unrestricted `supabase db push`/);
});

test("privacy runbook preserves gateway HMAC verification and export delivery gate", () => {
  assert.match(runbook, /--no-verify-jwt/);
  assert.match(runbook, /HMAC verification over the exact raw body/);
  assert.match(runbook, /result_delivered_at/);
  assert.match(runbook, /merchant receipt/);
  assert.match(runbook, /Candidate TOML declaration is source-only/);
});

test("privacy runbook explicitly prohibits production cutover without approval", () => {
  assert.match(runbook, /No production deployment is authorized or performed/);
  assert.match(runbook, /must be explicitly approved/);
});

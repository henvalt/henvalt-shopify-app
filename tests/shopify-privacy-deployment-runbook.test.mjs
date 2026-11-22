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
    "202611220006_shopify_privacy_export_acknowledgement.sql",
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

const cutoverRunbook = readFileSync("docs/HENVALT_V1_CONTROLLED_RELEASE_CUTOVER_RUNBOOK_2026-11-22.md", "utf8");

test("controlled cutover runbook lists every candidate migration in exact chronological order", () => {
  const migrations = [
    "202611210001_provider_send_interlock_v1.sql",
    "202611210002_pixel_consent_and_marketing_gate.sql",
    "202611210003_dashboard_confirmed_revenue_metrics.sql",
    "202611210004_align_shopify_token_refresh_window.sql",
    "202611210005_shopify_webhook_replay_enqueue.sql",
    "202611210006_shopify_webhook_replay_load.sql",
    "202611210007_shopify_webhook_single_roundtrip_ingress.sql",
    "202611210008_shopify_replay_lease_fencing.sql",
    "202611210009_shopify_replay_business_write_fencing.sql",
    "202611210010_shopify_replay_complete_ingest_write_fencing.sql",
    "202611210011_shopify_replay_write_lease_heartbeat.sql",
    "202611210012_shopify_privacy_tenant_fk_index.sql",
    "202611220001_shopify_privacy_claim_and_minimization.sql",
    "202611220002_shopify_privacy_redaction_guards.sql",
    "202611220003_shopify_privacy_retention_cron.sql",
    "202611220004_shopify_privacy_signed_payload_idempotency.sql",
    "202611220005_shopify_privacy_queue_worker.sql",
    "202611220006_shopify_privacy_export_acknowledgement.sql",
    "202611220007_shopify_replay_tenant_binding.sql",
    "202611220008_shopify_replay_object_tenant_binding.sql",
    "202611220009_mailersend_delivery_envelope_binding.sql",
    "202611220010_promote_confirmed_recovery_ledger.sql",
    "202611220011_billing_refund_credit_offsets.sql",
    "202611220012_dashboard_net_revenue_series.sql",
    "202611220013_shopify_order_edit_revenue_reconciliation.sql",
    "202611220014_billing_result_lock_order_and_monotonicity.sql",
    "202611220015_billing_claim_subscription_lock.sql",
    "202611220016_billing_deterministic_failure_reconciliation.sql",
  ];
  let cursor = -1;
  for (const migration of migrations) {
    const next = cutoverRunbook.indexOf(migration);
    assert.ok(next > cursor, "Missing or out-of-order migration: " + migration);
    cursor = next;
  }
  assert.equal((cutoverRunbook.match(/\.sql\x60/g) || []).length >= migrations.length, true);
  assert.match(cutoverRunbook, /Do not run an unrestricted \x60supabase db push\x60/);
});

test("controlled cutover runbook pins the three live workflow identities and forbids a fourth", () => {
  assert.match(cutoverRunbook, /6368d539-708f-494a-8be8-b9601d0e8607/);
  assert.match(cutoverRunbook, /32e50bf7-4cbd-4070-bbba-f259ed17b369/);
  assert.match(cutoverRunbook, /621ae6ce-a006-4fed-a70e-acf774c360fb/);
  assert.match(cutoverRunbook, /Do not create a fourth workflow/);
  assert.match(cutoverRunbook, /No production migration, function deployment, workflow publication/);
});

test("controlled cutover runbook records legacy billing route and release blockers", () => {
  assert.match(cutoverRunbook, /control_plane_verify_api_token/);
  assert.match(cutoverRunbook, /control_plane_record_billing_usage_result/);
  assert.match(cutoverRunbook, /late failure can therefore overwrite a previously submitted state/);
  assert.match(cutoverRunbook, /henvalt-shopify-usage-billing/);
  assert.match(cutoverRunbook, /henvalt-billing-reconciliation/);
  assert.match(cutoverRunbook, /Current release decision: NO-GO/);
});

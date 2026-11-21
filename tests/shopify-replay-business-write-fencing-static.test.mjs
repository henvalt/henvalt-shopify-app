import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const migration = readFileSync(
  "supabase/migrations/202611210009_shopify_replay_business_write_fencing.sql",
  "utf8",
);
const workerSpec = readFileSync(
  "docs/N8N_SHOPIFY_WEBHOOK_REPLAY_WORKER_CANDIDATE.md",
  "utf8",
);

test("replay business-write guard locks and validates the current lease in-transaction", () => {
  assert.match(migration, /assert_shopify_replay_lease_for_write/);
  assert.match(migration, /FOR UPDATE/);
  assert.match(migration, /lease_expires_at > clock_timestamp\(\)/);
  assert.match(migration, /job_type = 'process_shopify_webhook'/);
  assert.match(migration, /status = 'CLAIMED'::henvalt\.job_status/);
  assert.match(migration, /locked_by = p_worker_id/);
  assert.match(migration, /lease_id = p_lease_id/);
});

test("replay write wrappers cover each declared business mutation family", () => {
  for (const name of [
    "upsert_customer_fenced",
    "apply_shopify_email_consent_update_fenced",
    "bind_session_alias_fenced",
    "upsert_canonical_event_fenced",
    "upsert_checkout_fenced",
    "create_opportunity_idempotent_fenced",
    "create_intervention_and_enqueue_fenced",
    "project_order_from_event_fenced",
    "evaluate_order_attribution_fenced",
    "create_revenue_adjustment_fenced",
    "process_shopify_revenue_adjustment_fenced",
    "deactivate_shopify_connection_on_uninstall_fenced",
    "stop_recovery_after_order_fenced",
  ]) {
    assert.match(migration, new RegExp(`FUNCTION henvalt\\.${name}\\(`), name);
    assert.match(workerSpec, new RegExp(name), `worker spec must document ${name}`);
  }
});

test("worker specification forbids unfenced writes and records scope limitation", () => {
  assert.match(workerSpec, /must call these wrappers/);
  assert.match(workerSpec, /must not call their unfenced counterparts/);
  assert.match(workerSpec, /not proof that the entire replay subflow has been rewired/);
});

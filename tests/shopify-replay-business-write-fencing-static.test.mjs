import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const migration = readFileSync(
  "supabase/migrations/202611210009_shopify_replay_business_write_fencing.sql",
  "utf8",
);
const completionMigration = readFileSync(
  "supabase/migrations/202611210010_shopify_replay_complete_ingest_write_fencing.sql",
  "utf8",
);
const workerSpec = readFileSync(
  "docs/N8N_SHOPIFY_WEBHOOK_REPLAY_WORKER_CANDIDATE.md",
  "utf8",
);
const activeIngestSnapshot = JSON.parse(readFileSync(
  "tests/fixtures/n8n-shopify-ingest-route-snapshot.json",
  "utf8",
));
const writeMap = JSON.parse(readFileSync(
  "n8n/shopify-ingest-replay-write-map.json",
  "utf8",
));

test("replay business-write guard locks and validates the current lease in-transaction", () => {
  assert.match(migration, /assert_shopify_replay_lease_for_write/);
  assert.match(migration, /FOR UPDATE/);
  assert.match(migration, /lease_expires_at > clock_timestamp\(\)/);
  assert.match(migration, /job_type = 'process_shopify_webhook'/);
  assert.match(migration, /status = 'CLAIMED'::henvalt\.job_status/);
  assert.match(migration, /locked_by = p_worker_id/);
  assert.match(migration, /lease_id = p_lease_id/);
});

test("replay write wrappers cover every discovered active-ingest mutation family", () => {
  const migration009Names = [
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
    "mark_webhook_processed_fenced",
    "mark_webhook_failed_fenced",
  ];
  const migration010Names = [
    "apply_eligibility_fenced",
    "create_recovery_sequence_fenced",
    "post_recovery_to_ledger_and_measure_billing_fenced",
    "defer_payment_webhook_reconciliation_fenced",
  ];
  for (const name of migration009Names) {
    assert.match(migration, new RegExp("FUNCTION henvalt\\." + name + "\\("), name);
    assert.match(workerSpec, new RegExp(name), "worker spec must document " + name);
  }
  for (const name of migration010Names) {
    assert.match(completionMigration, new RegExp("FUNCTION henvalt\\." + name + "\\("), name);
    assert.match(workerSpec, new RegExp(name), "worker spec must document " + name);
  }
});

test("worker specification forbids unfenced writes and records scope limitation", () => {
  assert.match(workerSpec, /must call these wrappers/);
  assert.match(workerSpec, /must not call their unfenced counterparts/);
  assert.match(workerSpec, /not proof that the entire replay subflow has been rewired/);
});

test("audited active-ingest replay mutation map is complete and points only to fenced wrappers", () => {
  assert.equal(writeMap.source_workflow, "HENVALT_INGEST");
  assert.equal(writeMap.inspected_active_version, "6368d539-708f-494a-8be8-b9601d0e8607");
  assert.ok(writeMap.replay_mutations.length >= 18);
  const names = writeMap.replay_mutations.map((item) => item.fenced_rpc);
  assert.equal(new Set(names).size, names.length, "fenced RPC names must be unique");
  const allMigrations = migration + "\n" + completionMigration;
  for (const item of writeMap.replay_mutations) {
    assert.ok(item.node && item.current_rpc && item.fenced_rpc, "mapping entries must be complete");
    assert.ok(allMigrations.includes("FUNCTION henvalt." + item.fenced_rpc + "("),
      "missing fenced wrapper for " + item.node + ": " + item.fenced_rpc);
    assert.ok(workerSpec.includes(item.fenced_rpc),
      "worker contract omits " + item.fenced_rpc);
  }
  assert.ok(writeMap.requirements.some((item) => item.includes("does not imply the active workflow")));
});

test("fenced wrapper signatures put the lease tuple first and guard before mutation", () => {
  const allMigrations = migration + "\n" + completionMigration;
  for (const item of writeMap.replay_mutations) {
    const definition = new RegExp(
      "CREATE OR REPLACE FUNCTION henvalt\\." + item.fenced_rpc +
      "\\(([\\s\\S]*?)\\)\\s*RETURNS[\\s\\S]*?AS \\$function\\$([\\s\\S]*?)\\$function\\$",
      "i",
    ).exec(allMigrations);
    assert.ok(definition, "missing complete wrapper definition: " + item.fenced_rpc);
    const args = definition[1].replace(/\s+/g, " ").trim();
    assert.ok(
      args.startsWith("p_job_id uuid, p_worker_id text, p_lease_id uuid"),
      item.fenced_rpc + " must take the exact lease tuple first",
    );
    const body = definition[2];
    const guardAt = body.indexOf("PERFORM henvalt.assert_shopify_replay_lease_for_write(p_job_id,p_worker_id,p_lease_id)");
    assert.ok(guardAt >= 0, item.fenced_rpc + " must validate the current lease");
    const mutationAt = body.indexOf("henvalt." + item.current_rpc + "(");
    if (mutationAt >= 0) {
      assert.ok(guardAt < mutationAt, item.fenced_rpc + " must validate before the underlying mutation");
    } else {
      const directUpdateAt = body.indexOf("UPDATE henvalt.webhook_events");
      assert.ok(directUpdateAt >= 0 && guardAt < directUpdateAt,
        item.fenced_rpc + " must guard its direct webhook update");
    }
  }
});

test("the live active-ingest mutation inventory is exactly covered by the replay write map", () => {
  assert.equal(activeIngestSnapshot.workflowId, writeMap.source_workflow);
  assert.equal(activeIngestSnapshot.activeVersionId, writeMap.inspected_active_version);
  const active = activeIngestSnapshot.activeMutationInventory;
  assert.ok(Array.isArray(active) && active.length === 18);
  const mapped = writeMap.replay_mutations;
  assert.equal(mapped.length, active.length);
  const mapByRpc = new Map(mapped.map((item) => [item.current_rpc, item]));
  for (const item of active) {
    const mappedItem = mapByRpc.get(item.rpc);
    assert.ok(mappedItem, "active mutating RPC is missing from replay map: " + item.rpc);
    assert.equal(mappedItem.node, item.node);
  }
  assert.equal(mapByRpc.size, active.length, "replay map must not contain duplicate or unobserved RPCs");
});

import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const contract = JSON.parse(readFileSync(
  "n8n/shopify-recovery-replay-branch-contract.json",
  "utf8",
));
const workerSpec = readFileSync(
  "docs/N8N_SHOPIFY_WEBHOOK_REPLAY_WORKER_CANDIDATE.md",
  "utf8",
);
const writeMap = JSON.parse(readFileSync(
  "n8n/shopify-ingest-replay-write-map.json",
  "utf8",
));

test("recovery replay candidate is pinned to the inspected three-workflow system", () => {
  assert.equal(contract.workflow_count, 3);
  assert.equal(contract.recovery_workflow.name, "HENVALT_RECOVERY");
  assert.equal(contract.recovery_workflow.id, "3GEDoeCA4paXTaDF");
  assert.equal(
    contract.recovery_workflow.inspected_active_version,
    "32e50bf7-4cbd-4070-bbba-f259ed17b369",
  );
  assert.equal(contract.status, "candidate-only; not an exported or deployed n8n workflow");
  assert.equal(contract.production_boundary.active_workflows_modified, false);
  assert.equal(contract.production_boundary.workflow_published, false);
  assert.equal(contract.production_boundary.production_database_changed, false);
});

test("intervention and replay claims remain separate and type-restricted", () => {
  const recovery = contract.recovery_workflow;
  assert.match(
    recovery.existing_intervention_claim.sql,
    /claim_next_job\(\$1, ARRAY\['execute_intervention'\]::text\[\]\)/,
  );
  assert.equal(recovery.existing_intervention_claim.generic_rpcs_allowed_for[0], "execute_intervention");
  assert.match(recovery.replay_claim.sql, /claim_shopify_replay_job\(\$1, 180\)/);
  assert.equal(recovery.replay_claim.job_type, "process_shopify_webhook");
  assert.equal(recovery.replay_claim.claim_must_be_separate_from_generic_claim, true);
  assert.ok(recovery.replay_guard.reject_unknown_job_types);
  assert.equal(recovery.replay_guard.required_payload_field, "payload.webhook_id");
  assert.deepEqual(recovery.replay_claim.required_claim_fields, [
    "job_id", "worker_id", "lease_id", "lease_expires_at",
  ]);
});

test("scheduler contract bounds both queues so neither can starve", () => {
  const scheduling = contract.recovery_workflow.scheduling;
  assert.match(scheduling.fairness, /one intervention claim and one replay claim/);
  assert.equal(scheduling.no_queue_may_starve_the_other, true);
  assert.equal(scheduling.existing_intervention_business_branch_must_remain_semantically_unchanged, true);
  assert.equal(scheduling.order.length, 4);
  assert.match(scheduling.order[1], /every intervention terminal outcome/);
  assert.match(scheduling.order[2], /no intervention was claimed/);
});

test("replay load, completion and retry always carry the exact lease tuple", () => {
  const replay = contract.recovery_workflow.replay_claim;
  for (const sql of [
    replay.load_sql,
    replay.completion_sql,
    replay.retry_sql,
  ]) {
    assert.match(sql, /\$1, \$2, \$3/);
  }
  assert.deepEqual(replay.load_arguments, ["job_id", "worker_id", "lease_id"]);
  assert.deepEqual(contract.recovery_workflow.ingest_subflow_input_allowlist, [
    "job_id", "worker_id", "lease_id",
  ]);
  assert.equal(contract.recovery_workflow.replay_outcomes.ingest_success_requires, "mark_webhook_processed === true");
  assert.match(replay.retry_sql, /\$4, \$5/);
  assert.equal(replay.retry_delay_seconds_default, 300);
  assert.equal(replay.retry_delay_seconds_max, 3600);
});

test("every audited Shopify replay mutation is required to use its transaction-local fenced RPC", () => {
  const fencing = contract.recovery_workflow.replay_write_contract;
  assert.equal(fencing.require_transaction_local_fenced_rpc_for_every_mutation, true);
  assert.equal(fencing.require_sequential_writes, true);
  assert.equal(fencing.require_exact_lease_tuple_on_every_write, true);
  assert.equal(fencing.forbid_unfenced_mutation_rpcs, true);
  assert.equal(writeMap.source_workflow, "HENVALT_INGEST");
  assert.ok(writeMap.replay_mutations.length >= 18);
  for (const item of writeMap.replay_mutations) {
    assert.ok(item.fenced_rpc);
    assert.ok(workerSpec.includes(item.fenced_rpc), `worker spec omits ${item.fenced_rpc}`);
  }
});

test("forbidden shortcuts and production cutover are explicitly blocked", () => {
  const forbidden = contract.recovery_workflow.explicitly_forbidden.join("\n");
  assert.match(forbidden, /claim_next_job/);
  assert.match(forbidden, /complete_job or henvalt\.retry_job/);
  assert.match(forbidden, /raw payload/);
  assert.match(forbidden, /in parallel/);
  assert.match(forbidden, /HENVALT_DELIVERY/);
  assert.equal(contract.production_boundary.workflow_published, false);
  assert.equal(contract.production_boundary.provider_sending_enabled, false);
});

const activeSnapshot = JSON.parse(readFileSync(
  "tests/fixtures/n8n-recovery-route-snapshot.json",
  "utf8",
));

test("read-only active recovery snapshot proves replay support is not live yet", () => {
  assert.equal(activeSnapshot.workflowId, contract.recovery_workflow.id);
  assert.equal(
    activeSnapshot.activeVersionId,
    contract.recovery_workflow.inspected_active_version,
  );
  assert.deepEqual(activeSnapshot.activeClaimJobTypes, ["execute_intervention"]);
  assert.equal(activeSnapshot.replayJobTypeCurrentlyClaimed, false);
  assert.equal(activeSnapshot.generalWebhookReplayLaunchBlocker, true);
  assert.equal(activeSnapshot.normalizeGuard.replayJobsPassCurrentGuard, false);
});

test("every existing intervention terminal node hands control to the replay claim", () => {
  const recovery = contract.recovery_workflow;
  assert.deepEqual(recovery.intervention_terminal_nodes, [
    "Complete Job",
    "Retry Job",
    "Retry Preflight Job",
    "Retry Delivery Job",
    "Retry Pipeline Job",
  ]);
  assert.deepEqual(
    recovery.scheduling.must_attempt_replay_after,
    recovery.intervention_terminal_nodes,
  );
});

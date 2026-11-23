import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const read = (path) => readFileSync(new URL(path, import.meta.url), "utf8");
const audit = JSON.parse(read("./fixtures/delivery-generation-production-integration-audit.json"));
const n8n = JSON.parse(read("./fixtures/n8n-delivery-generation-contract-snapshot.json"));
const handler = read("../supabase/functions/henvalt-mailersend-delivery/handler.mjs");
const report = read("../docs/DELIVERY_GENERATION_PRODUCTION_INTEGRATION_AUDIT_2026-11-23.md");
const modelDoc = read("../docs/DELIVERY_GENERATION_MODEL_CANDIDATE.md");
const migration = read("../supabase/migrations/202611230002_delivery_generation_schema_and_retry_rpc.sql");
const egressMigration = read("../supabase/migrations/202611230003_delivery_provider_egress_fence.sql");
const prodShapeAcceptance = read("./delivery-generation-production-shaped-acceptance.sql");

test("live delivery-generation audit is explicitly read-only and pinned to the inspected active workflow", () => {
  assert.equal(audit.production_schema_was_not_mutated, true);
  assert.equal(audit.active_workflow.active, true);
  assert.equal(audit.active_workflow.version_id, "621ae6ce-a006-4fed-a70e-acf774c360fb");
  assert.equal(audit.active_workflow.node_count, 62);
  assert.equal(n8n.version_id, audit.active_workflow.version_id);
  assert.equal(n8n.active, true);
});

test("both direct result callers and the separate provider webhook path remain represented", () => {
  assert.equal(audit.active_workflow.direct_record_delivery_result_callers, 2);
  assert.deepEqual(audit.active_workflow.paths.normal_delivery, [
    "authorize_delivery_request",
    "henvalt-mailersend-delivery",
    "record_delivery_result",
  ]);
  assert.deepEqual(audit.active_workflow.paths.manual_one_off, [
    "reauthorize_one_off_test_delivery",
    "henvalt-mailersend-delivery",
    "record_delivery_result",
  ]);
  assert.deepEqual(audit.active_workflow.paths.provider_webhook, [
    "verify_mailersend_webhook_signature_api",
    "process_mailersend_webhook_event",
  ]);
  assert.equal(n8n.assertions.record_delivery_result_direct_calls, 2);
});

test("the production unique index is recorded as a hard blocker to multiple generations", () => {
  assert.equal(audit.live_constraints.unique_intervention_index.name, "ux_delivery_request_intervention");
  assert.deepEqual(audit.live_constraints.unique_intervention_index.columns, ["tenant_id", "intervention_id"]);
  assert.equal(audit.live_constraints.unique_intervention_index.blocks_multiple_generations, true);
  assert.equal(audit.live_constraints.candidate_email_usage_reservation_tables_deployed, false);
});

test("lock-order audit records the live request-first paths that must be reconciled", () => {
  assert.deepEqual(audit.live_lock_order.create_delivery_request, ["recovery_interventions", "delivery_requests"]);
  assert.deepEqual(audit.live_lock_order.record_delivery_result, ["delivery_requests", "recovery_interventions"]);
  assert.deepEqual(audit.live_lock_order.process_mailersend_webhook_event, [
    "provider_events_insert",
    "delivery_requests_for_update",
    "record_delivery_result",
  ]);
  assert.deepEqual(audit.live_lock_order.get_mailersend_token_for_delivery, [
    "delivery_requests_update_without_parent_lock",
  ]);
});

test("legacy one-off request reset is explicitly identified as incompatible with immutable generations", () => {
  assert.equal(audit.legacy_one_off_reauthorization.resets_failed_request_to_pending, true);
  assert.equal(audit.legacy_one_off_reauthorization.clears_provider_claimed_at, true);
  assert.equal(audit.legacy_one_off_reauthorization.must_be_replaced_or_disabled_for_generation_cutover, true);
  assert.equal(audit.legacy_one_off_reauthorization.token_rpc_contains_hard_coded_test_allowlist, true);
  assert.equal(audit.service_role_execution.can_reauthorize_one_off, true);
  assert.equal(audit.service_role_execution.can_claim_provider_token, true);
  assert.equal(audit.service_role_execution.can_record_delivery_result, true);
  assert.equal(audit.service_role_execution.can_process_provider_webhook, true);
  assert.match(report, /`service_role` can execute all four relevant RPCs/);
  assert.match(report, /The generation cutover must replace this RPC with a fail-closed response/);
});

test("current Edge Function has no durable pre-egress fence yet; local boolean is not mistaken for one", () => {
  assert.equal(audit.provider_edge_function.egress_marker_is_durable_in_database, false);
  assert.equal(audit.provider_edge_function.current_egress_marker_is_process_local_boolean, true);
  assert.match(handler, /providerEgressStarted = true/);
  assert.match(handler, /api\.mailersend\.com\/v1\/email/);
  assert.doesNotMatch(handler, /mark_delivery_provider_egress_started/);
  assert.match(report, /durable egress-start RPC after envelope authorization and before the provider HTTP call/);
});

test("late acceptance is kept separate from the terminal delivery-result state machine", () => {
  assert.equal(audit.late_acceptance.existing_processor_uses_delivery_tag_for_resolution, false);
  assert.equal(audit.late_acceptance.record_delivery_result_rejects_transition_from_failed, true);
  assert.equal(audit.late_acceptance.separate_late_acceptance_settlement_required, true);
  assert.match(modelDoc, /Late acceptance after a prior release/);
  assert.match(report, /Late acceptance is a separate settlement path/);
});

test("production-shaped migration is an additive, guarded first slice—not a cutover", () => {
  assert.match(migration, /DO NOT APPLY TO PRODUCTION/);
  assert.match(migration, /DELIVERY_GENERATION_PREREQUISITES_MISSING/);
  assert.match(migration, /DROP INDEX henvalt\.ux_delivery_request_intervention/);
  assert.match(migration, /UNIQUE INDEX ux_delivery_request_intervention_generation/);
  assert.match(migration, /CREATE OR REPLACE FUNCTION henvalt\.create_delivery_retry_generation/);
  assert.match(migration, /auth\.role\(\) IS DISTINCT FROM 'service_role'/);
  assert.match(migration, /APPEND_ONLY_RELEASE_EVIDENCE_MISSING/);
  assert.match(migration, /DELIVERY_GENERATION_LEDGER_IS_APPEND_ONLY/);
  assert.doesNotMatch(migration, /provider_claimed_at IS NOT NULL/);
  assert.doesNotMatch(migration, /mark_delivery_provider_egress_started/);
  assert.match(prodShapeAcceptance, /provider_claimed_at/);
  assert.match(prodShapeAcceptance, /retry without append-only release event was accepted/);
  assert.match(prodShapeAcceptance, /closed interlock allowed provider egress/);
  assert.match(prodShapeAcceptance, /provider egress fence allowed a second crossing/);
});

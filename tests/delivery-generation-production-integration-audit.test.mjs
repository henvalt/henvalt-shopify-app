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
const lockOrderMigration = read("../supabase/migrations/202611230004_delivery_lifecycle_parent_first_lock_order.sql");
const lockOrderAcceptance = read("./delivery-lifecycle-lock-order-acceptance.sql");
const legacyOneOffMigration = read("../supabase/migrations/202611230005_disable_legacy_one_off_delivery.sql");
const legacyOneOffAcceptance = read("./legacy-one-off-delivery-disable-acceptance.sql");
const lateAcceptanceMigration = read("../supabase/migrations/202611230006_late_provider_acceptance_incidents.sql");
const webhookRoutingMigration = read("../supabase/migrations/202611230007_mailersend_webhook_generation_routing.sql");
const lateAcceptanceAcceptance = read("./delivery-generation-production-shaped-late-acceptance.sql");
const webhookRoutingAcceptance = read("./delivery-generation-production-shaped-webhook-routing.sql");
const retryJobMigration = read("../supabase/migrations/202611240001_delivery_retry_generation_jobs.sql");
const retryJobAcceptance = read("./delivery-generation-retry-job-acceptance.sql");
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

test("candidate Edge Function commits the durable egress fence before MailerSend; production remains unchanged", () => {
  assert.equal(audit.provider_edge_function.candidate_handler_calls_durable_egress_rpc, true);
  assert.equal(audit.provider_edge_function.production_database_has_egress_marker, false);
  assert.equal(audit.provider_edge_function.process_local_boolean_is_diagnostic_only, true);
  assert.match(handler, /mark_mailersend_provider_egress_started/);
  assert.match(handler, /egressFenceStarted !== true/);
  assert.match(handler, /providerEgressStarted = true/);
  assert.ok(handler.includes("https://api.mailersend.com/v1/email"));
  assert.ok(handler.indexOf("assert_mailersend_delivery_envelope") < handler.indexOf("mark_mailersend_provider_egress_started"));
  assert.ok(handler.indexOf("mark_mailersend_provider_egress_started") < handler.indexOf("https://api.mailersend.com/v1/email"));
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


test("candidate lifecycle patch imposes parent-first locks across all four database entry points", () => {
  assert.match(lockOrderMigration, /authorize_delivery_request/);
  assert.match(lockOrderMigration, /get_mailersend_token_for_delivery/);
  assert.match(lockOrderMigration, /record_delivery_result/);
  assert.match(lockOrderMigration, /process_mailersend_webhook_event/);
  assert.match(lockOrderMigration, /DELIVERY_LOCK_ORDER_AUTHORIZATION_PATCH_ANCHOR_MISMATCH/);
  assert.match(lockOrderMigration, /DELIVERY_LOCK_ORDER_TOKEN_PATCH_ANCHOR_MISMATCH/);
  assert.match(lockOrderMigration, /DELIVERY_LOCK_ORDER_RESULT_PATCH_ANCHOR_MISMATCH/);
  assert.match(lockOrderMigration, /DELIVERY_LOCK_ORDER_WEBHOOK_PATCH_FAILED/);
  assert.match(lockOrderMigration, /PERFORM 1 FROM henvalt\.recovery_interventions/);
  assert.match(lockOrderAcceptance, /authorization parent-first lock order missing/);
  assert.match(lockOrderAcceptance, /token parent-first lock order missing/);
  assert.match(lockOrderAcceptance, /result parent-first lock order missing/);
  assert.match(lockOrderAcceptance, /webhook still locks child before result settlement/);
});


test("legacy one-off test delivery routes are explicitly disabled before immutable-generation cutover", () => {
  assert.match(legacyOneOffMigration, /LEGACY_ONE_OFF_DELIVERY_DISABLED_FOR_IMMUTABLE_GENERATIONS/);
  assert.match(legacyOneOffMigration, /LEGACY_ONE_OFF_TOKEN_ALLOWLIST_PATCH_FAILED/);
  assert.match(legacyOneOffMigration, /REVOKE ALL ON FUNCTION henvalt\.reauthorize_one_off_test_delivery/);
  assert.match(legacyOneOffMigration, /REVOKE ALL ON FUNCTION henvalt\.prepare_one_off_test_delivery/);
  assert.match(legacyOneOffAcceptance, /hard-coded one-off token allowlist survived cutover patch/);
  assert.match(legacyOneOffAcceptance, /normal tenant-scoped token claim was broken/);
  assert.match(legacyOneOffAcceptance, /legacy one-off reauthorization did not fail closed/);
  assert.match(legacyOneOffAcceptance, /legacy one-off preparation did not fail closed/);
});


test("late provider acceptance creates durable incident evidence without rewriting attempts", () => {
  assert.match(lateAcceptanceMigration, /settle_late_provider_acceptance/);
  assert.match(lateAcceptanceMigration, /EXACT_TENANT_AND_DELIVERY_TAG_REQUIRED/);
  assert.match(lateAcceptanceMigration, /LATE_PROVIDER_ACCEPTANCE/);
  assert.match(lateAcceptanceMigration, /FOR UPDATE/);
  assert.match(lateAcceptanceMigration, /delivery_generation_incidents/);
  assert.match(lateAcceptanceMigration, /status='CONSUMED'/);
  assert.match(lateAcceptanceMigration, /delivery_attempt_id,provider_status_code,reason/);
  assert.match(lateAcceptanceMigration, /historical_attempts_preserved/);
  assert.match(lateAcceptanceAcceptance, /historical delivery attempts were rewritten or fabricated/);
  assert.match(lateAcceptanceAcceptance, /duplicate incident inserted/);
  assert.match(lateAcceptanceAcceptance, /mismatched delivery tag was accepted/);
});

test("MailerSend sent and delivered webhooks resolve exact delivery tags before late settlement", () => {
  assert.match(webhookRoutingMigration, /v_delivery_request_tag uuid/);
  assert.match(webhookRoutingMigration, /MAILERSEND_WEBHOOK_EXACT_TAG_MATCH_PATCH_FAILED/);
  assert.match(webhookRoutingMigration, /settle_late_provider_acceptance\(v_event\)/);
  assert.match(webhookRoutingMigration, /activity\.sent/);
  assert.match(webhookRoutingMigration, /activity\.delivered/);
  assert.match(webhookRoutingMigration, /MAILERSEND_ACCEPTANCE_REQUIRES_EXACT_DELIVERY_TAG/);
  assert.match(webhookRoutingAcceptance, /normal activity\.sent did not settle current generation/);
  assert.match(webhookRoutingAcceptance, /late webhook did not freeze parent/);
  assert.match(webhookRoutingAcceptance, /mismatched delivery tag was accepted/);
});


test("pre-provider delivery retry creates a dedicated bounded generation job with immutable envelope", () => {
  assert.match(retryJobMigration, /enqueue_delivery_retry_generation_job/);
  assert.match(retryJobMigration, /execute_delivery_retry_generation/);
  assert.match(retryJobMigration, /retry_job_id uuid/);
  assert.match(retryJobMigration, /provider_response->>'henvalt_delivery_stage' <> 'pre_provider'/);
  assert.match(retryJobMigration, /v_previous\.generation_number >= 3/);
  assert.match(retryJobMigration, /load_delivery_retry_envelope/);
  assert.match(retryJobMigration, /render_sender_identity_footer/);
  assert.match(retryJobMigration, /render_email_plain_text/);
  assert.match(retryJobMigration, /DELIVERY_RETRY_JOB_CLAIM_INVALID/);
  assert.match(retryJobMigration, /p_expected_delivery_attempt_id uuid/);
  assert.match(retryJobMigration, /DELIVERY_RETRY_EXPECTED_ATTEMPT_STALE/);
  assert.match(retryJobMigration, /render_sender_identity_footer/);
  assert.match(retryJobMigration, /v_request\.status <> 'PENDING'/);
  assert.match(retryJobMigration, /m\.id=v_request\.message_reference/);
  assert.match(retryJobMigration, /REVOKE ALL ON FUNCTION/);
  assert.match(retryJobMigration, /GRANT EXECUTE ON FUNCTION/);
  assert.match(retryJobAcceptance, /expected RETRY_QUEUED/);
  assert.match(retryJobAcceptance, /source intervention job was not completed atomically/);
  assert.match(retryJobAcceptance, /immutable message envelope/);
  assert.match(retryJobAcceptance, /wrong worker loaded a delivery retry envelope/);
  assert.match(retryJobAcceptance, /mismatched attempt identity was accepted/);
  assert.match(retryJobAcceptance, /frozen intervention exposed a retry envelope/);
  assert.match(retryJobAcceptance, /ambiguous provider outcome incorrectly queued retry/);
  assert.match(retryJobAcceptance, /generation limit did not terminally dead-letter/);
});

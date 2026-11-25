import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const read = (path) => readFileSync(path, "utf8");
const migration = read("supabase/migrations/202611240001_delivery_retry_generation_jobs.sql");
const contract = JSON.parse(read("n8n/shopify-recovery-delivery-retry-branch-contract.json"));
const recoveryBuilder = read("n8n/shopify-recovery-candidate-builder.mjs");
const deliveryBuilder = read("n8n/shopify-delivery-candidate-builder.mjs");\nconst billingWorker = read("supabase/functions/henvalt-shopify-usage-billing/handler.mjs");
const recoveryFixture = JSON.parse(read("n8n/fixtures/henvalt-recovery-active-2026-11-24.sanitized.json"));
const retryAcceptance = read("tests/delivery-generation-retry-job-acceptance.sql");
const raceRetryWins = read("tests/delivery-generation-retry-wins-late-acceptance-race-postgres.sh");
const raceLateWins = read("tests/delivery-generation-late-acceptance-before-egress-race-postgres.sh");
const raceEgressWins = read("tests/delivery-generation-egress-before-late-acceptance-race-postgres.sh");
const reservationAcceptance = read("tests/email-usage-reservation-postgres-acceptance.sql");
const reservationConcurrency = read("tests/email-usage-reservation-concurrency-postgres.sh");
const reservationSettlementConcurrency = read("tests/email-usage-reservation-settlement-concurrency-postgres.sh");
const lifecycleAcceptance = read("tests/delivery-generation-parent-first-lock-order-acceptance.sql");

test("staging contract is pinned to the inspected three-workflow baseline", () => {
  assert.equal(contract.workflow_count, 3);
  assert.equal(contract.target.workflow_id, recoveryFixture.workflow.id);
  assert.equal(contract.target.inspected_active_version, recoveryFixture.source.active_version_id);
  assert.equal(contract.target.baseline_node_count, recoveryFixture.workflow.nodes.length);
  assert.equal(contract.safety.active_recovery_workflow_modified, false);
  assert.equal(contract.safety.active_delivery_workflow_modified, false);
  assert.equal(contract.safety.workflow_published, false);
  assert.equal(contract.safety.workflow_executed, false);
  assert.equal(contract.safety.provider_sending_enabled, false);
  assert.equal(contract.safety.production_database_changed, false);
  assert.equal(contract.safety.fourth_workflow_created, false);
});

test("retry enqueue is fenced by tenant, source lease, request, attempt and generation", () => {
  for (const token of [
    "p_tenant_id uuid", "p_source_job_id uuid", "p_worker_id text",
    "p_expected_delivery_request_id uuid", "p_expected_delivery_attempt_id uuid",
    "DELIVERY_RETRY_SOURCE_JOB_CLAIM_INVALID", "DELIVERY_RETRY_EXPECTED_REQUEST_STALE",
    "DELIVERY_RETRY_EXPECTED_ATTEMPT_STALE", "DELIVERY_RETRY_JOB_GENERATION_STALE",
    "clock_timestamp()"
  ]) assert.ok(migration.includes(token), `missing migration fence: ${token}`);
});

test("ambiguous outcomes cannot retry and generation ceiling dead-letters", () => {
  assert.equal(contract.retry_eligibility.ambiguous_provider_outcomes_retryable, false);
  assert.equal(contract.retry_eligibility.provider_response_stage_retryable, false);
  assert.equal(contract.job_model.max_total_generations, 3);
  assert.equal(contract.job_model.max_automatic_retries, 2);
  assert.match(migration, /provider_egress_started_at IS NOT NULL/);
  assert.match(migration, /provider_events/);
  assert.match(migration, /v_previous\.generation_number >= 3/);
  assert.match(migration, /'DEAD_LETTER'/);
  assert.match(retryAcceptance, /ambiguous provider outcome incorrectly queued retry/);
  assert.match(retryAcceptance, /generation limit did not terminally dead-letter/);
});

test("retry uses immutable canonical message envelope", () => {
  assert.equal(contract.immutable_envelope.content_regenerated, false);
  assert.equal(contract.immutable_envelope.recipient_replaced, false);
  assert.equal(contract.immutable_envelope.tracking_token_replaced, false);
  assert.match(migration, /load_delivery_retry_envelope/);
  assert.match(migration, /m\.id=v_request\.message_reference/);
  assert.match(migration, /m\.recipient=v_request\.recipient_reference/);
  assert.match(migration, /render_sender_identity_footer/);
  assert.match(migration, /render_email_plain_text/);
  assert.match(retryAcceptance, /immutable message envelope/);
});

test("recovery routes retry jobs through the existing delivery workflow", () => {
  assert.match(recoveryBuilder, /execute_delivery_retry_generation/);
  assert.match(recoveryBuilder, /Load Delivery Retry Envelope/);
  assert.match(recoveryBuilder, /Build Delivery Retry Payload/);
  assert.match(recoveryBuilder, /Call HENVALT_DELIVERY/);
  assert.match(recoveryBuilder, /Retry Delivery Generation Enqueue Job/);
  assert.match(deliveryBuilder, /retry_job_id/);
  assert.match(deliveryBuilder, /retry_worker_id/);
  assert.match(deliveryBuilder, /retry_generation_number/);
  assert.equal(contract.workflow_count, 3);
});

test("race scripts assert all three retry and late-acceptance orderings", () => {
  assert.match(raceRetryWins, /retry-generation vs late-acceptance race passed; parent frozen before next claim/);
  assert.match(raceLateWins, /late acceptance before provider-egress race passed/);
  assert.match(raceEgressWins, /provider egress before late acceptance race passed/);
  assert.match(retryAcceptance, /late provider acceptance/);
  assert.match(retryAcceptance, /retry generation/);
});

test("reservation acceptance includes both real two-session concurrency scripts", () => {
  assert.match(reservationAcceptance, /reservation/);
  assert.match(reservationConcurrency, /two-session email quota reservation concurrency acceptance passed/);
  assert.match(reservationSettlementConcurrency, /concurrent provider rejection\/acceptance settlement acceptance passed/);
  assert.match(lifecycleAcceptance, /delivery lifecycle parent-first lock order acceptance passed/);
});

test("candidate workflow builders retain inactive no-send isolation", () => {
  assert.match(deliveryBuilder, /HENVALT_DELIVERY_CANDIDATE_NO_SEND/);
  assert.match(deliveryBuilder, /No-Send Provider Stub/);
  assert.match(deliveryBuilder, /no_send_candidate: true/);
  assert.match(deliveryBuilder, /REMOVED_ONE_OFF_NODES/);
  assert.match(recoveryBuilder, /workflow\.active = false/);
  assert.match(recoveryBuilder, /availableInMCP: false/);
});

test("staging is not inferred from CI and network denial remains mandatory", () => {
  const matrix = read("docs/v1-whole-system-staging-acceptance-matrix.md");
  assert.match(matrix, /isolated staging/i);
  assert.match(matrix, /No isolated Supabase staging project/i);
  assert.match(matrix, /NO-GO/i);
  assert.match(matrix, /network-denied|network deny|provider stub/i);
  assert.match(matrix, /workflow version|workflow IDs/i);\n  assert.match(matrix, /HENVALT_SHOPIFY_BILLING_EGRESS_ENABLED/);\n  assert.match(matrix, /appUsageRecordCreate/);\n  assert.match(billingWorker, /HENVALT_SHOPIFY_BILLING_EGRESS_ENABLED !== "true"/);\n  assert.match(billingWorker, /billing_egress_disabled/);
});

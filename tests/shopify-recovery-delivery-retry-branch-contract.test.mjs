import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const contract = JSON.parse(readFileSync(
  "n8n/shopify-recovery-delivery-retry-branch-contract.json",
  "utf8",
));
const migration = readFileSync(
  "supabase/migrations/202611240001_delivery_retry_generation_jobs.sql",
  "utf8",
);
const recoveryBuilder = readFileSync(
  "n8n/shopify-recovery-candidate-builder.mjs",
  "utf8",
);
const deliveryBuilder = readFileSync(
  "n8n/shopify-delivery-candidate-builder.mjs",
  "utf8",
);
const acceptance = readFileSync(
  "tests/delivery-generation-retry-job-acceptance.sql",
  "utf8",
);
const snapshot = JSON.parse(readFileSync(
  "n8n/fixtures/henvalt-recovery-active-2026-11-24.sanitized.json",
  "utf8",
));

test("retry branch remains pinned to the current three-workflow recovery baseline", () => {
  assert.equal(contract.workflow_count, 3);
  assert.equal(contract.target.workflow_id, snapshot.workflow.id);
  assert.equal(contract.target.inspected_active_version, snapshot.source.active_version_id);
  assert.equal(contract.target.baseline_node_count, snapshot.workflow.nodes.length);
  assert.equal(contract.safety.active_recovery_workflow_modified, false);
  assert.equal(contract.safety.active_delivery_workflow_modified, false);
  assert.equal(contract.safety.workflow_published, false);
  assert.equal(contract.safety.workflow_executed, false);
  assert.equal(contract.safety.production_database_changed, false);
  assert.equal(contract.safety.fourth_workflow_created, false);
});

test("retry job is created only from exact pre-provider failure and released quota evidence", () => {
  assert.match(migration, /provider_response->>'henvalt_delivery_stage' <> 'pre_provider'/);
  assert.match(migration, /v_reservation.status <> 'RELEASED'/);
  assert.match(migration, /last_attempt_id IS DISTINCT FROM v_attempt.id/);
  assert.match(migration, /event_type='RELEASED'/);
  assert.match(migration, /provider_events/);
  assert.match(migration, /provider_egress_started_at IS NOT NULL/);
  assert.equal(contract.retry_eligibility.ambiguous_provider_outcomes_retryable, false);
  assert.equal(contract.retry_eligibility.provider_response_stage_retryable, false);
});

test("exact request and attempt identity are locked before retry generation creation", () => {
  assert.match(migration, /p_expected_delivery_request_id uuid/);
  assert.match(migration, /p_expected_delivery_attempt_id uuid/);
  assert.match(migration, /DELIVERY_RETRY_EXPECTED_REQUEST_STALE/);
  assert.match(migration, /DELIVERY_RETRY_EXPECTED_ATTEMPT_STALE/);
  assert.match(migration, /FOR UPDATE/);
  assert.match(recoveryBuilder, /body\.delivery_attempt_id/);
  assert.match(recoveryBuilder, /body\.delivery_request_id/);
});

test("retry jobs are bounded and source completion is transactional with queue insertion", () => {
  assert.match(migration, /v_previous\.generation_number >= 3/);
  assert.match(migration, /'DEAD_LETTER'/);
  assert.match(migration, /'execute_delivery_retry_generation'/);
  assert.match(migration, /status='SUCCEEDED',completed_at=clock_timestamp\(\)/);
  assert.match(migration, /delivery_retry_jobs/);
  assert.equal(contract.job_model.max_total_generations, 3);
  assert.equal(contract.job_model.max_automatic_retries, 2);
});

test("retry loader is worker-bound, current-generation-only, and reuses canonical stored content", () => {
  assert.match(migration, /load_delivery_retry_envelope/);
  assert.match(migration, /DELIVERY_RETRY_JOB_CLAIM_INVALID/);
  assert.match(migration, /v_request\.status <> 'PENDING'/);
  assert.match(migration, /m\.id=v_request\.message_reference/);
  assert.match(migration, /render_sender_identity_footer/);
  assert.match(migration, /render_email_plain_text/);
  assert.match(migration, /m\.recipient=v_request\.recipient_reference/);
  assert.equal(contract.immutable_envelope.content_regenerated, false);
  assert.equal(contract.immutable_envelope.recipient_replaced, false);
  assert.equal(contract.immutable_envelope.tracking_token_replaced, false);
});

test("recovery candidate claims retry jobs and routes them through stored envelope, not AI generation", () => {
  assert.match(recoveryBuilder, /execute_delivery_retry_generation/);
  assert.match(recoveryBuilder, /Resume Delivery Retry Generation/);
  assert.match(recoveryBuilder, /Load Delivery Retry Envelope/);
  assert.match(recoveryBuilder, /Build Delivery Retry Payload/);
  assert.match(recoveryBuilder, /Create Delivery Retry Generation Job/);
  assert.match(recoveryBuilder, /Claim Shopify Replay Job/);
  assert.match(recoveryBuilder, /body\.pre_provider_failure === true/);
  assert.match(recoveryBuilder, /const retryable = preProviderFailure/);
  assert.doesNotMatch(recoveryBuilder, /const retryable = state === "REJECTED"/);
  assert.match(deliveryBuilder, /delivery_attempt_id/);
  assert.match(deliveryBuilder, /pre_provider_failure/);
});

test("acceptance proves ambiguous outcomes do not retry and generation three is terminal", () => {
  assert.match(acceptance, /ambiguous provider outcome incorrectly queued retry/);
  assert.match(acceptance, /generation limit did not terminally dead-letter/);
  assert.match(acceptance, /wrong worker loaded a delivery retry envelope/);
  assert.match(acceptance, /immutable message envelope/);
});


test("retry job terminal outcomes preserve fair replay scheduling in the existing worker", () => {
  assert.ok(recoveryBuilder.includes(`c["Resume Delivery Retry Decision?"] = { main: [[edge("Is Delivery Retry Generation Job?")], [edge("Claim Shopify Replay Job")]] };`));
  assert.ok(recoveryBuilder.includes(`c["Delivery Retry Enqueued?"] = { main: [[edge("Claim Shopify Replay Job")], [edge("Complete Job")]] };`));
  assert.ok(recoveryBuilder.includes(`c["Retry Delivery Generation Enqueue Job"] = { main: [[edge("Claim Shopify Replay Job")]`));
  assert.equal(contract.workflow_count, 3);
});

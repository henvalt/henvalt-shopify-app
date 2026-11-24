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
  assert.match(migration, /provider_response->>'henvalt_delivery_stage' IS DISTINCT FROM 'pre_provider'/);
  assert.match(migration, /v_reservation.status <> 'RELEASED'/);
  assert.match(migration, /last_attempt_id IS DISTINCT FROM v_attempt.id/);
  assert.match(migration, /event_type='RELEASED'/);
  assert.match(migration, /provider_events/);
  assert.match(migration, /provider_egress_started_at IS NOT NULL/);
  assert.equal(contract.retry_eligibility.ambiguous_provider_outcomes_retryable, false);
  assert.equal(contract.retry_eligibility.provider_response_stage_retryable, false);
});

test("exact request and attempt identity are locked before retry generation creation", () => {
  const coreStart = migration.indexOf("CREATE OR REPLACE FUNCTION henvalt.enqueue_delivery_retry_generation_job(\n  p_tenant_id");
  const coreEnd = migration.indexOf("CREATE OR REPLACE FUNCTION henvalt.enqueue_delivery_retry_generation_job(\n  p_intervention_id", coreStart + 1);
  const core = migration.slice(coreStart, coreEnd);
  const reservationStart = core.indexOf("FROM henvalt.email_usage_reservations");
  const reservationEnd = core.indexOf("IF NOT FOUND", reservationStart);
  assert.ok(reservationStart >= 0 && reservationEnd > reservationStart);
  assert.doesNotMatch(core.slice(reservationStart, reservationEnd), /FOR UPDATE/);
  assert.match(core, /Canonical lifecycle lock order: intervention -> request -> reservation/);
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
  assert.match(migration, /delivery_retry_jobs_append_only/);
  assert.match(acceptance, /append-only retry job mapping missing/);
  assert.match(acceptance, /retry job mapping update was accepted/);
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

import { buildRecoveryCandidate } from "../n8n/shopify-recovery-candidate-builder.mjs";
import { buildDeliveryCandidate } from "../n8n/shopify-delivery-candidate-builder.mjs";

const recoveryFixture = JSON.parse(readFileSync(
  "n8n/fixtures/henvalt-recovery-active-2026-11-24.sanitized.json",
  "utf8",
));
const replayManifest = JSON.parse(readFileSync(
  "n8n/shopify-recovery-replay-graph-patch.json",
  "utf8",
));
const replayNormalizer = readFileSync(
  "n8n/shopify-replay-claim-normalizer-node-candidate.js",
  "utf8",
);

test("generated recovery graph routes retry generations through the existing delivery subworkflow", () => {
  const { workflow, audit } = buildRecoveryCandidate(
    recoveryFixture.workflow,
    replayManifest,
    replayNormalizer,
  );
  const nodes = new Map(workflow.nodes.map((node) => [node.name, node]));
  const target = (name, output = 0) => workflow.connections[name]?.main?.[output]?.[0]?.node ?? null;

  assert.equal(workflow.nodes.length, contract.target.candidate_node_count);
  assert.equal(workflow.nodeCount, workflow.nodes.length);
  assert.equal(workflow.active, false);
  assert.equal(workflow.settings.availableInMCP, false);
  assert.equal(audit.delivery_retry_generation_branch, true);
  assert.equal(nodes.get("Claim Due Job").parameters.query.includes("'execute_delivery_retry_generation'"), true);
  assert.equal(target("Job Claimed?", 0), "Claimed Job Valid?");
  assert.equal(target("Claimed Job Valid?", 0), "Resume Delivery Retry Generation");
  assert.equal(target("Claimed Job Valid?", 1), "Complete Job");
  assert.equal(target("Resume Delivery Retry Decision?", 0), "Is Delivery Retry Generation Job?");
  assert.equal(target("Resume Delivery Retry Decision?", 1), "Claim Shopify Replay Job");
  assert.equal(target("Is Delivery Retry Generation Job?", 0), "Load Delivery Retry Envelope");
  assert.equal(target("Is Delivery Retry Generation Job?", 1), "Atomic Claim Intervention");
  assert.equal(target("Delivery Retry Envelope Valid?", 0), "Build Delivery Retry Payload");
  assert.equal(target("Build Delivery Retry Payload"), "Call HENVALT_DELIVERY");
  assert.equal(target("Classify Delivery Failure"), "Retry Job Claim Lost?");
  assert.equal(target("Retry Job Claim Lost?", 0), "Stop Delivery Retry Job Claim Lost");
  assert.equal(target("Retry Job Claim Lost?", 1), "Resolve Delivery Failure");
  assert.equal(target("Delivery Retryable?", 0), "Create Delivery Retry Generation Job");
  assert.equal(target("Create Delivery Retry Generation Job"), "Delivery Retry Enqueued?");
  assert.equal(target("Delivery Retry Enqueued?", 0), "Claim Shopify Replay Job");
  assert.equal(target("Delivery Retry Enqueued?", 1), "Complete Job");

  const retryPayload = nodes.get("Build Delivery Retry Payload").parameters.jsCode;
  assert.match(retryPayload, /delivery_request_id/);
  assert.match(retryPayload, /idempotency_key/);
  assert.doesNotMatch(retryPayload, /Grok Generate|Create Tracking Token|Create Unsubscribe Token/);
  assert.equal(nodes.get("Call HENVALT_DELIVERY").parameters.workflowId.value, "00000000-0000-4000-8000-999999999996");
});


test("generated recovery worker guard validates complete retry-generation identity", () => {
  const { workflow } = buildRecoveryCandidate(
    recoveryFixture.workflow,
    replayManifest,
    replayNormalizer,
  );
  const code = workflow.nodes.find((node) => node.name === "Normalize & Guard").parameters.jsCode;
  const run = (row) => new Function("$", "$json", code)(
    (name) => ({ first: () => ({ json: { worker_id: "recovery-worker-test" } }) }),
    row,
  );
  const intervention = run({
    id: "11111111-1111-4111-8111-111111111111",
    job_type: "execute_intervention",
    payload: { intervention_id: "22222222-2222-4222-8222-222222222222" },
  });
  assert.equal(intervention.json.claim_valid, true);
  const retry = run({
    id: "33333333-3333-4333-8333-333333333333",
    job_type: "execute_delivery_retry_generation",
    tenant_id: "44444444-4444-4444-8444-444444444444",
    payload: {
      tenant_id: "44444444-4444-4444-8444-444444444444",
      intervention_id: "55555555-5555-4555-8555-555555555555",
      delivery_request_id: "66666666-6666-4666-8666-666666666666",
      generation_number: 2,
    },
  });
  assert.equal(retry.json.claim_valid, true);
  const missingIdentity = run({
    id: "77777777-7777-4777-8777-777777777777",
    job_type: "execute_delivery_retry_generation",
    payload: {
      intervention_id: "55555555-5555-4555-8555-555555555555",
      delivery_request_id: "66666666-6666-4666-8666-666666666666",
      generation_number: 2,
    },
  });
  assert.equal(missingIdentity.json.claim_valid, false);
  const fractionalGeneration = run({
    id: "88888888-8888-4888-8888-888888888888",
    job_type: "execute_delivery_retry_generation",
    tenant_id: "44444444-4444-4444-8444-444444444444",
    payload: {
      intervention_id: "55555555-5555-4555-8555-555555555555",
      delivery_request_id: "66666666-6666-4666-8666-666666666666",
      generation_number: 2.5,
    },
  });
  assert.equal(fractionalGeneration.json.claim_valid, false);
});

test("delivery failure classifier retries only a server-marked FAILED pre-provider response with both exact IDs", () => {
  const { workflow } = buildRecoveryCandidate(
    recoveryFixture.workflow,
    replayManifest,
    replayNormalizer,
  );
  const code = workflow.nodes.find((node) => node.name === "Classify Delivery Failure").parameters.jsCode;
  const identity = {
    intervention_id: "11111111-1111-4111-8111-111111111111",
    tenant_id: "22222222-2222-4222-8222-222222222222",
    job_id: "33333333-3333-4333-8333-333333333333",
    worker_id: "recovery-worker-test",
  };
  const classify = (body) => new Function("$", "$json", code)(
    (name) => ({ item: { json: identity } }),
    { body },
  ).json;
  const accepted = classify({
    state: "FAILED",
    pre_provider_failure: true,
    delivery_request_id: "44444444-4444-4444-8444-444444444444",
    delivery_attempt_id: "55555555-5555-4555-8555-555555555555",
  });
  assert.equal(accepted.retryable, true);
  const ambiguous = classify({
    state: "UNKNOWN",
    pre_provider_failure: false,
    delivery_request_id: "44444444-4444-4444-8444-444444444444",
    delivery_attempt_id: "55555555-5555-4555-8555-555555555555",
  });
  assert.equal(ambiguous.retryable, false);
  const providerResponse = classify({
    state: "FAILED",
    pre_provider_failure: false,
    delivery_request_id: "44444444-4444-4444-8444-444444444444",
    delivery_attempt_id: "55555555-5555-4555-8555-555555555555",
  });
  assert.equal(providerResponse.retryable, false);
  const missingAttempt = classify({
    state: "FAILED",
    pre_provider_failure: true,
    delivery_request_id: "44444444-4444-4444-8444-444444444444",
    delivery_attempt_id: null,
  });
  assert.equal(missingAttempt.retryable, false);
  const rejected = classify({
    state: "REJECTED",
    pre_provider_failure: true,
    delivery_request_id: "44444444-4444-4444-8444-444444444444",
    delivery_attempt_id: "55555555-5555-4555-8555-555555555555",
  });
  assert.equal(rejected.retryable, false);
  const claimLost = classify({
    state: "REJECTED",
    retry_job_claim_lost: true,
    delivery_request_id: "44444444-4444-4444-8444-444444444444",
    delivery_attempt_id: null,
  });
  assert.equal(claimLost.retry_job_claim_lost, true);
  assert.equal(claimLost.retryable, false);
  assert.equal(claimLost.final_status, "SENDING");
});


const deliveryFixture = JSON.parse(readFileSync(
  "n8n/fixtures/henvalt-delivery-active-2026-11-21.sanitized.json",
  "utf8",
));

test("delivery candidate propagates the exact recorded attempt and trusted pre-provider marker into recovery retry classifier", () => {
  const { workflow: delivery } = buildDeliveryCandidate(deliveryFixture.workflow);
  const { workflow: recovery } = buildRecoveryCandidate(
    recoveryFixture.workflow,
    replayManifest,
    replayNormalizer,
  );
  const nodeCode = (workflow, name) => workflow.nodes.find((node) => node.name === name).parameters.jsCode;
  const tenantId = "11111111-1111-4111-8111-111111111111";
  const interventionId = "22222222-2222-4222-8222-222222222222";
  const requestId = "33333333-3333-4333-8333-333333333333";
  const attemptId = "44444444-4444-4444-8444-444444444444";
  const correlationId = "55555555-5555-4555-8555-555555555555";

  const classifyDelivery = new Function("$", "$json", nodeCode(delivery, "Classify Result"))(
    (name) => ({
      item: { json: ({
        "Validate & Normalize": {
          precheck_ok: true,
          tenant_id: tenantId,
          intervention_id: interventionId,
          recovery_id: "66666666-6666-4666-8666-666666666666",
          opportunity_id: "77777777-7777-4777-8777-777777777777",
          correlation_id: correlationId,
        },
        "Authorize & Context": {
          statusCode: 200,
          body: { can_send: true, delivery_request_id: requestId, provider: "mailersend" },
        },
        "No-Send Provider Stub": {
          statusCode: 409,
          body: {
            error: "tenant_provider_credential_unavailable",
            henvalt_delivery_stage: "pre_provider",
          },
        },
      })[name] },
    }),
    {},
  );

  assert.equal(classifyDelivery.state, "FAILED");
  assert.equal(classifyDelivery.provider_response.henvalt_delivery_stage, "pre_provider");
  assert.equal(classifyDelivery.should_record_result, true);

  const buildResponse = new Function("$", "$json", nodeCode(delivery, "Build Delivery Response"))(
    (name) => ({
      item: { json: name === "Classify Result"
        ? classifyDelivery
        : { body: JSON.stringify(attemptId) } },
    }),
    {},
  ).json;

  assert.equal(buildResponse.body.state, "FAILED");
  assert.equal(buildResponse.body.delivery_request_id, requestId);
  assert.equal(buildResponse.body.delivery_attempt_id, attemptId);
  assert.equal(buildResponse.body.pre_provider_failure, true);

  const recoveryIdentity = {
    intervention_id: interventionId,
    tenant_id: tenantId,
    job_id: "88888888-8888-4888-8888-888888888888",
    worker_id: "recovery-worker-contract",
  };
  const classifyRecovery = new Function("$", "$json", nodeCode(recovery, "Classify Delivery Failure"))(
    () => ({ item: { json: recoveryIdentity } }),
    { body: buildResponse.body, statusCode: buildResponse.statusCode },
  ).json;

  assert.equal(classifyRecovery.retryable, true);
  assert.equal(classifyRecovery.delivery_request_id, requestId);
  assert.equal(classifyRecovery.delivery_attempt_id, attemptId);
  assert.equal(classifyRecovery.pre_provider_failure, true);
  assert.equal(classifyRecovery.reason, "PRE_PROVIDER_FAILURE");
});


test("recovery retry payload carries exact job lease identity through delivery normalization", () => {
  const { workflow: recovery } = buildRecoveryCandidate(
    recoveryFixture.workflow,
    replayManifest,
    replayNormalizer,
  );
  const { workflow: delivery } = buildDeliveryCandidate(deliveryFixture.workflow);
  const nodeCode = (workflow, name) => workflow.nodes.find((node) => node.name === name).parameters.jsCode;
  const jobId = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa";
  const tenantId = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb";
  const interventionId = "cccccccc-cccc-4ccc-8ccc-cccccccccccc";
  const requestId = "dddddddd-dddd-4ddd-8ddd-dddddddddddd";
  const workerId = "retry-worker-contract";

  const payload = new Function("$", "$json", nodeCode(recovery, "Build Delivery Retry Payload"))(
    (name) => ({ item: { json: {
      job_id: jobId,
      tenant_id: tenantId,
      intervention_id: interventionId,
      generation_number: 2,
      worker_id: workerId,
    } } }),
    {
      delivery_request_id: requestId,
      message_id: "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee",
      tenant_id: tenantId,
      intervention_id: interventionId,
      recipient: "retry@example.test",
      subject: "Stored subject",
      html_body: "<p>Stored body</p>",
      text_body: "Stored body",
      correlation_id: "ffffffff-ffff-4fff-8fff-ffffffffffff",
      idempotency_key: "deliver:" + interventionId + ":g2",
    },
  ).json;

  assert.equal(payload.delivery_generation_retry, true);
  assert.equal(payload.retry_job_id, jobId);
  assert.equal(payload.retry_worker_id, workerId);
  assert.equal(payload.retry_generation_number, 2);
  assert.equal(payload.metadata.delivery_generation_retry, true);

  const normalized = new Function("$input", "$json", nodeCode(delivery, "Validate & Normalize"))(
    { item: { json: payload } },
    {},
  );
  assert.equal(normalized.delivery_generation_retry, true);
  assert.equal(normalized.retry_job_id, jobId);
  assert.equal(normalized.retry_worker_id, workerId);
  assert.equal(normalized.retry_generation_number, 2);
  assert.equal(normalized.delivery_request_id, requestId);
  const authorizeNode = delivery.nodes.find((node) => node.name === "Authorize & Context");
  assert.ok(authorizeNode.parameters.url.endsWith("/rpc/authorize_delivery_request_with_retry_lease"));
  assert.match(authorizeNode.parameters.jsonBody, /p_retry_job_id/);
  assert.match(authorizeNode.parameters.jsonBody, /p_retry_worker_id/);
  assert.match(authorizeNode.parameters.jsonBody, /p_generation_number/);
  assert.match(deliveryBuilder, /retry_job_id/);
  assert.match(deliveryBuilder, /retry_worker_id/);
  assert.match(deliveryBuilder, /retry_generation_number/);
  assert.match(deliveryBuilder, /delivery_generation_retry/);
});


test("retry job claim loss stops before result persistence and leaves recovery intervention untouched", () => {
  const { workflow: delivery } = buildDeliveryCandidate(deliveryFixture.workflow);
  const { workflow: recovery } = buildRecoveryCandidate(
    recoveryFixture.workflow,
    replayManifest,
    replayNormalizer,
  );
  const nodeCode = (workflow, name) => workflow.nodes.find((node) => node.name === name).parameters.jsCode;
  const identity = {
    precheck_ok: true,
    tenant_id: "11111111-1111-4111-8111-111111111111",
    intervention_id: "22222222-2222-4222-8222-222222222222",
    recovery_id: "33333333-3333-4333-8333-333333333333",
    opportunity_id: "44444444-4444-4444-8444-444444444444",
    correlation_id: "55555555-5555-4555-8555-555555555555",
  };
  const classifyDelivery = new Function("$", "$json", nodeCode(delivery, "Classify Result"))(
    (name) => ({ item: { json: ({
      "Validate & Normalize": identity,
      "Authorize & Context": { statusCode: 200, body: { can_send: true, delivery_request_id: "66666666-6666-4666-8666-666666666666", provider: "mailersend" } },
      "No-Send Provider Stub": { statusCode: 409, body: {
        state: "REJECTED",
        failure_category: "RETRY_JOB_CLAIM_LOST",
        retry_job_claim_lost: true,
      } },
    })[name] } }),
    {},
  );
  assert.equal(classifyDelivery.retry_job_claim_lost, true);
  assert.equal(classifyDelivery.should_record_result, false);

  const deliveryResponse = new Function("$", "$json", nodeCode(delivery, "Build Delivery Response"))(
    (name) => ({ item: { json: name === "Classify Result" ? classifyDelivery : {} } }),
    {},
  ).json;
  assert.equal(deliveryResponse.body.retry_job_claim_lost, true);
  assert.equal(deliveryResponse.body.delivery_attempt_id, null);

  const classifyRecovery = new Function("$", "$json", nodeCode(recovery, "Classify Delivery Failure"))(
    () => ({ item: { json: {
      intervention_id: identity.intervention_id,
      tenant_id: identity.tenant_id,
      job_id: "77777777-7777-4777-8777-777777777777",
      worker_id: "stale-worker",
    } } }),
    { body: deliveryResponse.body, statusCode: deliveryResponse.statusCode },
  ).json;
  assert.equal(classifyRecovery.retry_job_claim_lost, true);
  assert.equal(classifyRecovery.retryable, false);
  assert.equal(classifyRecovery.final_status, "SENDING");
});


test("authorization-time retry lease loss is propagated without claiming or recording a delivery", () => {
  const { workflow: delivery } = buildDeliveryCandidate(deliveryFixture.workflow);
  const { workflow: recovery } = buildRecoveryCandidate(
    recoveryFixture.workflow,
    replayManifest,
    replayNormalizer,
  );
  const nodeCode = (workflow, name) => workflow.nodes.find((node) => node.name === name).parameters.jsCode;
  const identity = {
    precheck_ok: true,
    tenant_id: "11111111-1111-4111-8111-111111111111",
    intervention_id: "22222222-2222-4222-8222-222222222222",
    recovery_id: "33333333-3333-4333-8333-333333333333",
    opportunity_id: "44444444-4444-4444-8444-444444444444",
    correlation_id: "55555555-5555-4555-8555-555555555555",
  };
  const classified = new Function("$", "$json", nodeCode(delivery, "Classify Result"))(
    (name) => ({ item: { json: ({
      "Validate & Normalize": identity,
      "Authorize & Context": {
        statusCode: 200,
        body: { can_send: false, retry_job_claim_lost: true, reason: "RETRY_JOB_CLAIM_LOST" },
      },
      "No-Send Provider Stub": undefined,
    })[name] } }),
    {},
  );
  assert.equal(classified.retry_job_claim_lost, true);
  assert.equal(classified.should_record_result, false);

  const response = new Function("$", "$json", nodeCode(delivery, "Build Delivery Response"))(
    (name) => ({ item: { json: name === "Classify Result" ? classified : {} } }),
    {},
  ).json;
  assert.equal(response.body.retry_job_claim_lost, true);
  assert.equal(response.body.delivery_attempt_id, null);

  const recoveryResult = new Function("$", "$json", nodeCode(recovery, "Classify Delivery Failure"))(
    () => ({ item: { json: {
      intervention_id: identity.intervention_id,
      tenant_id: identity.tenant_id,
      job_id: "77777777-7777-4777-8777-777777777777",
      worker_id: "stale-worker",
    } } }),
    { body: response.body, statusCode: response.statusCode },
  ).json;
  assert.equal(recoveryResult.retry_job_claim_lost, true);
  assert.equal(recoveryResult.retryable, false);
  assert.equal(recoveryResult.final_status, "SENDING");
});

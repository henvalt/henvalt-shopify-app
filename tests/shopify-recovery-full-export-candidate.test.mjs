import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { buildRecoveryCandidate } from "../n8n/shopify-recovery-candidate-builder.mjs";

const fixture = JSON.parse(readFileSync("n8n/fixtures/henvalt-recovery-active-2026-11-24.sanitized.json", "utf8"));
const manifest = JSON.parse(readFileSync("n8n/shopify-recovery-replay-graph-patch.json", "utf8"));
const normalizer = readFileSync("n8n/shopify-replay-claim-normalizer-node-candidate.js", "utf8");
const candidateId = "00000000-0000-4000-8000-999999999997";
const ingestCandidateId = "00000000-0000-4000-8000-999999999999";

test("full recovery graph builds as a distinct inactive no-send export", () => {
  const result = buildRecoveryCandidate(fixture.workflow, manifest, normalizer);
  const w = result.workflow;
  assert.equal(fixture.workflow.nodes.length, 46);
  assert.equal(w.id, candidateId);
  assert.equal(w.name, "HENVALT_RECOVERY_CANDIDATE_NO_SEND");
  assert.equal(w.active, false);
  assert.equal(w.settings.availableInMCP, false);
  assert.equal(w.nodes.length, 75);
  assert.equal(result.audit.candidate_nodes, 75);
  assert.equal(result.audit.unique_node_ids, 75);
  assert.equal(result.audit.unique_node_names, 75);
  assert.equal(result.audit.credentials_removed, true);
  assert.equal(result.audit.webhook_ids_removed, true);
  assert.equal(result.audit.provider_send_nodes, 0);
  assert.ok(w.nodes.every((n) => !n.credentials && !n.webhookId));
  const serializedCandidate = JSON.stringify(w);
  const emailLeak = serializedCandidate.match(/[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}/i);
  if (emailLeak) {
    const leakIndex = serializedCandidate.indexOf(emailLeak[0]);
    assert.fail("Candidate contains email literal " + emailLeak[0] + " near " + serializedCandidate.slice(Math.max(0, leakIndex - 120), leakIndex + 120));
  }
});

test("recovery replay can call only the isolated INGEST candidate", () => {
  const w = buildRecoveryCandidate(fixture.workflow, manifest, normalizer).workflow;
  const call = w.nodes.find((n) => n.name === "Call HENVALT_INGEST Replay Entry");
  assert.equal(call.typeVersion, 1.4);
  assert.equal(call.parameters.workflowId.value, ingestCandidateId);
  const deliveryCall = w.nodes.find((n) => n.name === "Call HENVALT_DELIVERY");
  assert.equal(deliveryCall.parameters.workflowId.value, "00000000-0000-4000-8000-999999999996");
  assert.deepEqual(Object.keys(call.parameters.workflowInputs.value), ["job_id", "worker_id", "lease_id"]);
  assert.deepEqual(call.parameters.workflowInputs.value, {
    job_id: "={{ $('Normalize Shopify Replay Claim').item.json.job_id }}",
    worker_id: "={{ $('Normalize Shopify Replay Claim').item.json.worker_id }}",
    lease_id: "={{ $('Normalize Shopify Replay Claim').item.json.lease_id }}"
  });
  assert.equal(call.parameters.options.waitForSubWorkflow, true);
  assert.equal(call.onError, "continueErrorOutput");
});

test("all intervention terminal paths and empty-claim paths reach the replay scheduler safely", () => {
  const w = buildRecoveryCandidate(fixture.workflow, manifest, normalizer).workflow;
  for (const name of ["Complete Job","Retry Job","Retry Preflight Job","Retry Delivery Job","Retry Pipeline Job"]) {
    assert.equal(w.connections[name].main[0][0].node, "Claim Shopify Replay Job", name);
  }
  assert.equal(w.connections["Job Claimed?"].main[1][0].node, "Claim Shopify Replay Job");
  assert.equal(w.connections["Replay Job Claimed?"].main[1][0].node, "Loop Interventions");
  assert.equal(w.connections["Replay Claim Valid?"].main[1][0].node, "Stop Replay Lease Lost");
  assert.equal(w.connections["Replay Load Valid?"].main[1][0].node, "Retry Shopify Replay Job");
});

test("replay claim, load, complete and retry use lease-fenced SQL with stable tuple bindings", () => {
  const w = buildRecoveryCandidate(fixture.workflow, manifest, normalizer).workflow;
  const byName = new Map(w.nodes.map((n) => [n.name, n]));
  assert.equal(byName.get("Claim Shopify Replay Job").parameters.query, "SELECT * FROM henvalt.claim_shopify_replay_job($1, 180)");
  assert.equal(byName.get("Claim Shopify Replay Job").alwaysOutputData, true);
  assert.equal(byName.get("Claim Shopify Replay Job").onError, "stopWorkflow");
  assert.equal(byName.get("Load Shopify Replay Job").alwaysOutputData, true);
  assert.equal(byName.get("Load Shopify Replay Job").onError, "continueErrorOutput");
  assert.equal(byName.get("Complete Shopify Replay Job").parameters.query, "SELECT henvalt.complete_shopify_replay_job($1, $2, $3) AS result");
  assert.equal(byName.get("Retry Shopify Replay Job").parameters.query, "SELECT henvalt.retry_shopify_replay_job($1, $2, $3, $4, $5) AS result");
  assert.match(byName.get("Load Shopify Replay Job").parameters.options.queryReplacement, /job_id/);
  assert.match(byName.get("Load Shopify Replay Job").parameters.options.queryReplacement, /worker_id/);
  assert.match(byName.get("Load Shopify Replay Job").parameters.options.queryReplacement, /lease_id/);
  assert.match(byName.get("Retry Shopify Replay Job").parameters.options.queryReplacement, /SHOPIFY_REPLAY_PROCESSING_FAILED/);
});

test("completion accepts processed or confirmed deferred handoff and all failures fail closed", () => {
  const w = buildRecoveryCandidate(fixture.workflow, manifest, normalizer).workflow;
  assert.match(w.nodes.find((n) => n.name === "Replay Ingest Processed?").parameters.conditions.conditions[0].leftValue, /mark_webhook_processed === true/);
  assert.match(w.nodes.find((n) => n.name === "Replay Ingest Processed?").parameters.conditions.conditions[0].leftValue, /deferred_payment_handoff === true/);
  assert.equal(w.connections["Complete Shopify Replay Job"].main[1][0].node, "Stop Replay Lease Lost");
  assert.equal(w.connections["Replay Completion Accepted?"].main[1][0].node, "Stop Replay Lease Lost");
  assert.equal(w.connections["Retry Shopify Replay Job"].main[1][0].node, "Stop Replay Lease Lost");
  assert.equal(w.connections["Replay Retry Accepted?"].main[1][0].node, "Stop Replay Lease Lost");
  assert.equal(w.connections["Replay Already Processed?"].main[0][0].node, "Complete Shopify Replay Job");
});

test("candidate graph contains only known endpoints and no outbound provider node", () => {
  const w = buildRecoveryCandidate(fixture.workflow, manifest, normalizer).workflow;
  const names = new Set(w.nodes.map((n) => n.name));
  for (const [source, outputs] of Object.entries(w.connections)) {
    assert.ok(names.has(source), "unknown source " + source);
    for (const output of outputs.main || []) for (const edge of output || []) assert.ok(names.has(edge.node), "unknown target " + edge.node);
  }
  assert.ok(!w.nodes.some((n) => /MailerSend|provider send/i.test(n.name)));
  assert.equal(w.nodes.find((n) => n.name === "Claim Due Job").alwaysOutputData, true);
});


test("recovery worker claims only intervention and dedicated immutable delivery retry job types", () => {
  const w = buildRecoveryCandidate(fixture.workflow, manifest, normalizer).workflow;
  const claim = w.nodes.find((n) => n.name === "Claim Due Job");
  assert.match(claim.parameters.query, /execute_intervention/);
  assert.match(claim.parameters.query, /execute_delivery_retry_generation/);
  const normalize = w.nodes.find((n) => n.name === "Normalize & Guard").parameters.jsCode;
  assert.match(normalize, /delivery_request_id/);
  assert.match(normalize, /generation_number/);
  assert.match(normalize, /claimValid/);
  assert.equal(w.connections["Job Claimed?"].main[0][0].node, "Claimed Job Valid?");
  assert.equal(w.connections["Claimed Job Valid?"].main[0][0].node, "Resume Delivery Retry Generation");
  assert.equal(w.connections["Claimed Job Valid?"].main[1][0].node, "Complete Job");
});

test("retry generation resumes only from server-proven pre-provider evidence and the exact attempt ID", () => {
  const w = buildRecoveryCandidate(fixture.workflow, manifest, normalizer).workflow;
  const classifier = w.nodes.find((n) => n.name === "Classify Delivery Failure").parameters.jsCode;
  assert.match(classifier, /body\.pre_provider_failure === true/);
  assert.match(classifier, /body\.delivery_attempt_id/);
  assert.match(classifier, /body\.delivery_request_id/);
  assert.match(classifier, /state === "FAILED"/);
  assert.match(classifier, /const retryable = preProviderFailure/);
  assert.doesNotMatch(classifier, /SENDER_IDENTITY_NOT_CONFIGURED.*EMAIL_PROVIDER_NOT_CONFIGURED/);
  assert.equal(w.connections["Delivery Retryable?"].main[0][0].node, "Create Delivery Retry Generation Job");
  const create = w.nodes.find((n) => n.name === "Create Delivery Retry Generation Job");
  assert.match(create.parameters.query, /enqueue_delivery_retry_generation_job\(\$1,\$2,\$3,\$4,\$5\)/);
  assert.match(create.parameters.options.queryReplacement, /delivery_request_id/);
  assert.match(create.parameters.options.queryReplacement, /delivery_attempt_id/);
});

test("retry worker reloads the exact immutable message and never regenerates AI content", () => {
  const w = buildRecoveryCandidate(fixture.workflow, manifest, normalizer).workflow;
  const load = w.nodes.find((n) => n.name === "Load Delivery Retry Envelope");
  assert.match(load.parameters.query, /load_delivery_retry_envelope/);
  assert.equal(load.alwaysOutputData, true);
  const payload = w.nodes.find((n) => n.name === "Build Delivery Retry Payload").parameters.jsCode;
  for (const field of ["delivery_request_id","message_id","recipient","subject","html_body","text_body","tracking_token","idempotency_key"]) {
    assert.match(payload, new RegExp(field));
  }
  assert.doesNotMatch(payload, /Grok Generate|Validate AI Output|Create Tracking Token/);
  assert.equal(w.connections["Build Delivery Retry Payload"].main[0][0].node, "Call HENVALT_DELIVERY");
  assert.equal(w.connections["Delivery Retry Envelope Valid?"].main[1][0].node, "Fail Delivery Retry Envelope");
});

test("retry enqueue errors preserve the source job for an idempotent retry; ambiguous results never retry", () => {
  const w = buildRecoveryCandidate(fixture.workflow, manifest, normalizer).workflow;
  assert.equal(w.connections["Resume Delivery Retry Generation"].main[1][0].node, "Retry Delivery Retry Resume Job");
  assert.equal(w.connections["Load Delivery Retry Envelope"].main[1][0].node, "Retry Delivery Retry Job");
  assert.equal(w.connections["Create Delivery Retry Generation Job"].main[1][0].node, "Retry Delivery Generation Enqueue Job");
  assert.equal(w.connections["Delivery Retry Enqueued?"].main[0][0].node, "Claim Shopify Replay Job");
  assert.equal(w.connections["Delivery Retry Enqueued?"].main[1][0].node, "Complete Job");
  const retry = w.nodes.find((n) => n.name === "Retry Delivery Generation Enqueue Job").parameters.options.queryReplacement;
  assert.match(retry, /DELIVERY_RETRY_GENERATION_ENQUEUE_FAILED/);
});

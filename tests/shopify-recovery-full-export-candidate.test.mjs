import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { buildRecoveryCandidate } from "../n8n/shopify-recovery-candidate-builder.mjs";

const fixture = JSON.parse(readFileSync("n8n/fixtures/henvalt-recovery-active-2026-11-21.sanitized.json", "utf8"));
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
  assert.equal(w.nodes.length, 60);
  assert.equal(result.audit.candidate_nodes, 60);
  assert.equal(result.audit.unique_node_ids, 60);
  assert.equal(result.audit.unique_node_names, 60);
  assert.equal(result.audit.credentials_removed, true);
  assert.equal(result.audit.webhook_ids_removed, true);
  assert.equal(result.audit.provider_send_nodes, 0);
  assert.ok(w.nodes.every((n) => !n.credentials && !n.webhookId));
  assert.ok(!JSON.stringify(w).match(/[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}/i));
});

test("recovery replay can call only the isolated INGEST candidate", () => {
  const w = buildRecoveryCandidate(fixture.workflow, manifest, normalizer).workflow;
  const call = w.nodes.find((n) => n.name === "Call HENVALT_INGEST Replay Entry");
  assert.equal(call.typeVersion, 1.4);
  assert.equal(call.parameters.workflowId.value, ingestCandidateId);
  assert.deepEqual(Object.keys(call.parameters.workflowInputs.value), ["job_id", "worker_id", "lease_id"]);
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

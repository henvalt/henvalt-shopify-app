import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const contract = JSON.parse(readFileSync("n8n/shopify-ingest-replay-entry-candidate.json", "utf8"));
const envelope = readFileSync("n8n/shopify-ingest-replay-envelope-candidate.mjs", "utf8");
const ack = readFileSync("n8n/shopify-ingest-ack-classifier-candidate.mjs", "utf8");
const loadSql = readFileSync("supabase/migrations/202611210008_shopify_replay_lease_fencing.sql", "utf8");
const writes = readFileSync("n8n/shopify-ingest-replay-write-map.json", "utf8");
const ingressSql = readFileSync("supabase/migrations/202611210007_shopify_webhook_single_roundtrip_ingress.sql", "utf8");

test("replay entry remains candidate-only and inside the existing three workflows", () => {
  assert.match(contract.status, /candidate-only/);
  assert.equal(contract.workflow.id, "VTpfGKNtu1CSQ4Rv");
  assert.equal(contract.workflow.total_workflows, 3);
  assert.equal(contract.safety.active_workflow_published, false);
  assert.equal(contract.safety.fourth_workflow_created, false);
  assert.equal(contract.safety.provider_sending_enabled, false);
});

test("replay loader uses the exact migration 008 lease-fenced signature", () => {
  assert.match(loadSql, /FUNCTION henvalt\.load_shopify_webhook_replay_job\(\s*p_job_id uuid,\s*p_worker_id text,\s*p_lease_id uuid/s);
  assert.deepEqual(contract.design.lease_load.arguments, ["job_id", "worker_id", "lease_id"]);
  assert.match(contract.design.lease_load.rpc, /uuid,text,uuid/);
});

test("replay envelope requires trusted ingress attestation, exact tenant and live lease", () => {
  for (const token of [
    "ingress_hmac_verified !== true",
    "r.metadata?.shopify_webhook_id !== r.source_event_id",
    "r.tenant_id",
    "r.lease_expires_at",
    "c.lease_id",
    "replay_context",
  ]) assert.ok(envelope.includes(token), `envelope guard missing: ${token}`);
  assert.match(contract.design.envelope.payload_event_id, /source_event_id/);
  assert.ok(contract.design.envelope.does_not_emit.includes("HMAC header"));
});

test("public ingress only acknowledges a durable active replay job", () => {
  assert.match(ingressSql, /FUNCTION henvalt\.receive_shopify_webhook_v1/);
  assert.match(ack, /ACTIVE_JOB_STATES/);
  assert.match(ack, /legacy|409/i);
  assert.equal(contract.design.ingress_cutover.no_inline_processing_after_ack, true);
  assert.equal(contract.design.ingress_cutover.legacy_409_is_not_duplicate, true);
});

test("replay mutations use the audited write map and never downgrade to unfenced RPCs", () => {
  const map = JSON.parse(writes);
  assert.equal(map.replay_mutations.length, 18);
  assert.match(contract.design.shared_pipeline.downstream, /\*_fenced/);
  assert.match(contract.design.lifecycle.processed, /mark_webhook_processed_fenced/);
  assert.match(contract.design.lifecycle.failed, /mark_webhook_failed_fenced/);
});

test("deferred payment is a durable terminal handoff through the active recovery reconciler", () => {
  assert.match(contract.design.lifecycle.deferred_payment, /deferred_payment_handoff=true/);
  assert.equal(contract.design.lifecycle.deferred_payment_audit.observed_active, true);
  assert.equal(contract.design.lifecycle.deferred_payment_audit.trigger, "Every Minute");
  assert.equal(contract.design.lifecycle.deferred_payment_audit.node, "Reconcile Deferred Payment Webhooks");
  assert.match(contract.design.lifecycle.deferred_payment_audit.selection, /FOR UPDATE SKIP LOCKED/);
  assert.ok(contract.acceptance.some(x => /Deferred payment path: fenced defer RPC returns true/.test(x)));
});

test("no replay route is allowed to reach the delivery provider", () => {
  assert.ok(contract.acceptance.some(x => /No replay branch reaches HENVALT_DELIVERY/.test(x)));
});

import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const ingest = JSON.parse(readFileSync("n8n/HENVALT_INGEST_CANDIDATE_NO_SEND.json", "utf8"));
const recovery = JSON.parse(readFileSync("n8n/HENVALT_RECOVERY_CANDIDATE_NO_SEND.json", "utf8"));
const delivery = JSON.parse(readFileSync("n8n/HENVALT_DELIVERY_CANDIDATE_NO_SEND.json", "utf8"));
const workflows = [ingest, recovery, delivery];
const byName = (workflow) => new Map(workflow.nodes.map((node) => [node.name, node]));
const ids = {
  ingest: "00000000-0000-4000-8000-999999999999",
  recovery: "00000000-0000-4000-8000-999999999997",
  delivery: "00000000-0000-4000-8000-999999999996"
};

test("the isolated package contains exactly three distinct inactive candidate workflows", () => {
  assert.deepEqual(workflows.map((w) => w.name), [
    "HENVALT_INGEST_CANDIDATE_NO_SEND",
    "HENVALT_RECOVERY_CANDIDATE_NO_SEND",
    "HENVALT_DELIVERY_CANDIDATE_NO_SEND"
  ]);
  assert.deepEqual(workflows.map((w) => w.id), [ids.ingest, ids.recovery, ids.delivery]);
  assert.equal(new Set(workflows.map((w) => w.id)).size, 3);
  for (const w of workflows) {
    assert.equal(w.active, false);
    assert.equal(w.settings.availableInMCP, false);
    assert.ok(w.nodes.every((n) => !n.credentials && !n.webhookId));
    assert.ok(!JSON.stringify(w).match(/[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}/i));
  }
});

test("recovery subworkflow calls resolve only to the two candidate workflow IDs", () => {
  const nodes = byName(recovery);
  assert.equal(nodes.get("Call HENVALT_INGEST Replay Entry").parameters.workflowId.value, ids.ingest);
  assert.equal(nodes.get("Call HENVALT_DELIVERY").parameters.workflowId.value, ids.delivery);
  assert.notEqual(nodes.get("Call HENVALT_INGEST Replay Entry").parameters.workflowId.value, "VTpfGKNtu1CSQ4Rv");
  assert.notEqual(nodes.get("Call HENVALT_DELIVERY").parameters.workflowId.value, "CvVyybGJZSnklxiZ");
});

test("INGEST exposes the exact lease-bound three-field replay trigger", () => {
  const trigger = byName(ingest).get("Shopify Replay Entry Trigger");
  assert.ok(trigger);
  assert.equal(trigger.isTrigger, true);
  assert.equal(trigger.typeVersion, 1.1);
  assert.equal(trigger.parameters.inputSource, "workflowInputs");
  assert.equal(trigger.parameters.returnOutput, "lastRunOnly");
  assert.deepEqual(trigger.parameters.workflowInputs.values, [
    {name:"job_id",type:"string"},
    {name:"worker_id",type:"string"},
    {name:"lease_id",type:"string"}
  ]);
});

test("DELIVERY has no provider egress or one-off test-send path", () => {
  const nodes = byName(delivery);
  assert.equal(nodes.get("No-Send Provider Stub").type, "n8n-nodes-base.code");
  assert.ok(nodes.get("No-Send Provider Stub").parameters.jsCode.includes("no_send_candidate: true"));
  assert.equal(nodes.has("MailerSend Send"), false);
  assert.equal(nodes.has("MailerSend One-Off Test Email"), false);
  assert.equal(nodes.has("Prepare One-Off Test Delivery"), false);
  assert.equal(delivery.nodes.some((n) => n.parameters?.url && String(n.parameters.url).includes("/functions/v1/henvalt-mailersend-delivery")), false);
  assert.ok(delivery.nodes.filter((n) => n.type === "n8n-nodes-base.webhook")
    .every((n) => n.parameters.path.startsWith("henvalt/candidate-no-send/")));
  const classifier = nodes.get("Classify Result").parameters.jsCode;
  assert.ok(classifier.includes("NO_SEND_CANDIDATE"));
  assert.ok(classifier.includes("should_record_result: authorized && !"));
});

test("every graph connection in all three candidates resolves within its own workflow", () => {
  for (const w of workflows) {
    const names = new Set(w.nodes.map((n) => n.name));
    for (const [source, outputs] of Object.entries(w.connections || {})) {
      assert.ok(names.has(source), w.name + " missing source " + source);
      for (const output of outputs.main || []) for (const edge of output || []) {
        assert.ok(names.has(edge.node), w.name + " missing target " + edge.node);
      }
    }
  }
});


test("candidate endpoints cannot call the live Supabase project or reply-AI Worker", () => {
  const serialized = JSON.stringify(workflows);
  assert.equal(serialized.includes("ocyplckdojdubyrsxcxa.supabase.co"), false);
  assert.equal(serialized.includes("henvalt-reply-ai.chmuhammadrehan18.workers.dev"), false);
  assert.ok(serialized.includes("https://supabase-staging.invalid"));
  assert.ok(serialized.includes("https://reply-ai-staging.invalid"));
});

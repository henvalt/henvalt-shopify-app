import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const ingest = JSON.parse(readFileSync("n8n/HENVALT_INGEST_CANDIDATE_NO_SEND.json", "utf8"));
const recovery = JSON.parse(readFileSync("n8n/HENVALT_RECOVERY_CANDIDATE_BILLING_STAGING_ONLY.json", "utf8"));
const delivery = JSON.parse(readFileSync("n8n/HENVALT_DELIVERY_CANDIDATE_NO_SEND.json", "utf8"));
const workflows = [ingest, recovery, delivery];
const byName = (workflow) => new Map(workflow.nodes.map((node) => [node.name, node]));
const ids = {
  ingest: "00000000-0000-4000-8000-999999999999",
  recovery: "00000000-0000-4000-8000-999999999995",
  delivery: "00000000-0000-4000-8000-999999999996"
};

test("the isolated package contains exactly three distinct inactive candidate workflows", () => {
  assert.deepEqual(workflows.map((w) => w.name), [
    "HENVALT_INGEST_CANDIDATE_NO_SEND",
    "HENVALT_RECOVERY_CANDIDATE_BILLING_STAGING_ONLY",
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

test("synthetic checkout ingestion reaches opportunity and recovery-sequence creation", () => {
  const nodes = byName(ingest);
  for (const name of ["Supabase Ingest RPC", "Is Checkout Event?", "Has Checkout Data?", "Upsert Customer", "Upsert Checkout", "Score Recovery Intent", "High Intent?", "Create Opportunity", "Create Recovery Sequence"]) {
    assert.ok(nodes.has(name), "missing checkout-path node: " + name);
  }
  assert.equal(nodes.get("Supabase Ingest RPC").parameters.url,
    "https://supabase-staging.invalid/rest/v1/rpc/receive_shopify_webhook_v1");
  assert.equal(ingest.connections["Has Checkout Data?"].main[0][0].node, "Upsert Customer");
  assert.equal(ingest.connections["Upsert Customer"].main[0][0].node, "Upsert Checkout");
  assert.equal(ingest.connections["Upsert Checkout"].main[0][0].node, "Score Recovery Intent");
  assert.equal(ingest.connections["Score Recovery Intent"].main[0][0].node, "High Intent?");
  assert.equal(ingest.connections["High Intent?"].main[0][0].node, "Create Opportunity");
});

test("paid-order attribution is stopped, posted to the ledger and measured before webhook completion", () => {
  const nodes = byName(ingest);
  for (const name of ["Project Order From Event", "Evaluate Order Attribution", "Stop Recovery After Order", "Post Recovery To Ledger", "Process Shopify Order Edit Adjustment"]) {
    assert.ok(nodes.has(name), "missing order-attribution node: " + name);
  }
  assert.equal(ingest.connections["Is Order Event?"].main[0][0].node, "Project Order From Event");
  assert.equal(ingest.connections["Project Order From Event"].main[0][0].node, "Is Order Cancelled?");
  assert.equal(ingest.connections["Is Order Cancelled?"].main[1][0].node, "Evaluate Order Attribution");
  assert.equal(ingest.connections["Evaluate Order Attribution"].main[0][0].node, "Stop Recovery After Order");
  assert.equal(ingest.connections["Stop Recovery After Order"].main[0][0].node, "Post Recovery To Ledger");
  const billingUrl = nodes.get("Post Recovery To Ledger").parameters.url;
  assert.match(billingUrl, /https:\/\/supabase-staging\.invalid\/rest\/v1\/rpc\//);
  assert.match(billingUrl, /post_recovery_to_ledger_and_measure_billing_fenced/);
  assert.match(billingUrl, /post_recovery_to_ledger_and_measure_billing/);
  assert.equal(ingest.connections["Post Recovery To Ledger"].main[0][0].node, "Process Shopify Order Edit Adjustment");
  assert.equal(ingest.connections["Process Shopify Order Edit Adjustment"].main[0][0].node, "Mark Webhook Processed");
});

test("recovery subworkflow calls resolve only to the two candidate workflow IDs", () => {
  const nodes = byName(recovery);
  assert.equal(nodes.get("Call HENVALT_INGEST Replay Entry").parameters.workflowId.value, ids.ingest);
  assert.equal(nodes.get("Call HENVALT_DELIVERY").parameters.workflowId.value, ids.delivery);
  assert.notEqual(nodes.get("Call HENVALT_INGEST Replay Entry").parameters.workflowId.value, "VTpfGKNtu1CSQ4Rv");
  assert.notEqual(nodes.get("Call HENVALT_DELIVERY").parameters.workflowId.value, "CvVyybGJZSnklxiZ");
});

test("recovery keeps the billing scheduler inside the same three-workflow architecture", () => {
  const nodes = byName(recovery);
  const trigger = nodes.get("Every Minute");
  assert.ok(trigger);
  assert.ok(trigger.parameters);
  assert.ok((recovery.connections["Every Minute"]?.main?.[0] ?? [])
    .some((edge) => edge.node === "Find Shopify Usage Billing Shops"));
  const discover = nodes.get("Find Shopify Usage Billing Shops");
  const worker = nodes.get("Call Shopify Usage Billing Worker");
  assert.ok(discover && worker);
  assert.ok((recovery.connections["Find Shopify Usage Billing Shops"]?.main?.[0] ?? [])
    .some((edge) => edge.node === "Call Shopify Usage Billing Worker"));
  assert.match(discover.parameters.query, /billing_measurements/);
  assert.match(discover.parameters.query, /attribution_confidence = 'CONFIRMED'/);
  assert.match(discover.parameters.query, /test_mode = true/);
  assert.equal(worker.parameters.url, "https://supabase-staging.invalid/functions/v1/henvalt-shopify-usage-billing");
  assert.ok(!worker.credentials);
  assert.equal(recovery.name, "HENVALT_RECOVERY_CANDIDATE_BILLING_STAGING_ONLY");
  assert.equal(recovery.nodes.length, 76);
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

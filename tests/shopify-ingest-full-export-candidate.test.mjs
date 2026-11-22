import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { buildCandidate } from "../n8n/shopify-ingest-candidate-builder.mjs";

const source = JSON.parse(readFileSync("n8n/fixtures/henvalt-ingest-active-2026-11-21.sanitized.json","utf8"));
const map = JSON.parse(readFileSync("n8n/shopify-ingest-replay-write-map.json","utf8"));
const pinned = "6368d539-708f-494a-8be8-b9601d0e8607";
const findNode = (w,name) => w.nodes.find(n=>n.name===name);

test("full pinned 51-node active INGEST export builds an isolated no-send candidate", () => {
  const result = buildCandidate(source,map,pinned);
  const w = result.workflow;
  assert.equal(source.nodes.length,51);
  assert.equal(w.active,false);
  assert.equal(w.settings.availableInMCP,false);
  assert.equal(w.id,"00000000-0000-4000-8000-999999999999");
  assert.equal(w.name,"HENVALT_INGEST_CANDIDATE_NO_SEND");
  assert.equal(w.nodes.length,70);
  assert.equal(result.graphAudit.node_count,70);
  assert.equal(result.graphAudit.unique_node_ids,70);
  assert.equal(result.graphAudit.unique_node_names,70);
  assert.equal(result.audit.fenced_mutation_nodes,18);
  assert.equal(result.audit.active_workflow_modified,false);
  assert.ok(w.nodes.every(n=>!n.credentials && !n.webhookId));
  const normalizer=findNode(w,"Validate & Normalize");
  assert.match(normalizer.parameters.jsCode,/const eventType = source === "shopify" \\? shopifyTopic : \\(body\\.event_type \\|\\| body\\.type \\|\\| null\\);/);
  const webhook=w.nodes.find(n=>n.name==="Event Webhook");
  assert.equal(webhook.parameters.path,"henvalt/ingest-candidate-no-send");
  assert.equal(webhook.parameters.responseMode,"responseNode");
  assert.equal(webhook.parameters.options.rawBody,true,"Shopify HMAC must receive the exact raw request bytes");
  assert.equal(w.nodes.find(n=>n.name==="Supabase Ingest RPC").parameters.url,
    "https://supabase-staging.invalid/rest/v1/rpc/receive_shopify_webhook_v1");
  assert.ok(w.nodes.some(n=>n.name==="Respond to Shopify"));
  const replayTrigger = findNode(w,"Shopify Replay Entry Trigger");
  assert.ok(replayTrigger);
  assert.equal(replayTrigger.isTrigger,true);
  assert.equal(replayTrigger.typeVersion,1.1);
  assert.deepEqual(replayTrigger.parameters.workflowInputs.values,[
    {name:"job_id",type:"string"},
    {name:"worker_id",type:"string"},
    {name:"lease_id",type:"string"}
  ]);
  assert.equal(replayTrigger.parameters.inputSource,"workflowInputs");
  assert.equal(replayTrigger.parameters.returnOutput,"lastRunOnly");
  assert.equal(w.connections["Is Trusted Replay?"].main[0][0].node,"Resolve Shopify Tenant");
  assert.equal(w.connections["Is Trusted Replay?"].main[1][0].node,"Is Shopify Source?");
  assert.equal(findNode(w,"Verify Shopify HMAC"),undefined);
  assert.equal(findNode(w,"HMAC Verified?"),undefined);
  assert.match(findNode(w,"Supabase Ingest RPC").parameters.jsonBody,/p_raw_body_base64/);
  assert.match(findNode(w,"Supabase Ingest RPC").parameters.jsonBody,/p_hmac/);
  assert.match(findNode(w,"Classify Result").parameters.jsCode,/isUuid\(row\.webhook_id\)/);
  assert.match(findNode(w,"Classify Result").parameters.jsCode,/isUuid\(row\.replay_job_id\)/);
  assert.ok(w.nodes.every(n=>!/(MailerSend|send email|provider send)/i.test(n.name)));
});

test("non-Shopify events cannot enter the Shopify HMAC ingress RPC", () => {
  const w = buildCandidate(source,map,pinned).workflow;
  const byName = new Map(w.nodes.map(n=>[n.name,n]));
  assert.equal(w.connections["Is Trusted Replay?"].main[1][0].node,"Is Shopify Source?");
  assert.equal(w.connections["Is Replay Entry?"].main[1][0].node,"Is Shopify Source?");
  assert.equal(w.connections["Is Shopify Source?"].main[0][0].node,"Supabase Ingest RPC");
  assert.equal(w.connections["Is Shopify Source?"].main[1][0].node,"Build Unsupported Internal Source Response");
  const reject = byName.get("Build Unsupported Internal Source Response");
  assert.equal(reject.parameters.assignments.assignments.find(a=>a.name==="__http").value,422);
  assert.match(reject.parameters.assignments.assignments.find(a=>a.name==="__body").value,/unsupported_internal_source/);
  assert.equal(w.connections["Build Unsupported Internal Source Response"].main[0][0].node,"Respond to Shopify");
});

test("all 18 write paths are lease-fenced and every connection resolves", () => {
  const w=buildCandidate(source,map,pinned).workflow;
  const byName=new Map(w.nodes.map(n=>[n.name,n]));
  for (const entry of map.replay_mutations) {
    const node=byName.get(entry.node);
    assert.ok(node,entry.node+" exists");
    if(entry.node==="Deactivate Shopify Connection") {
      assert.match(node.parameters.query,new RegExp(entry.fenced_rpc));
      assert.match(node.parameters.options.queryReplacement,/r\.job_id/);
      assert.match(node.parameters.options.queryReplacement,/r\.lease_id/);
    } else {
      assert.match(node.parameters.url,new RegExp(entry.fenced_rpc));
      assert.match(node.parameters.jsonBody,/p_job_id/);
      assert.match(node.parameters.jsonBody,/p_worker_id/);
      assert.match(node.parameters.jsonBody,/p_lease_id/);
    }
  }
  for(const [from,outputs] of Object.entries(w.connections)) {
    assert.ok(byName.has(from),"missing connection source "+from);
    for(const output of outputs.main||[]) for(const edge of output||[]) {
      assert.ok(byName.has(edge.node),"missing connection target "+edge.node);
    }
  }
  assert.equal(w.connections["Replay Pipeline?"].main[0][0].node,"Renew Replay Lease Before Writes");
  assert.equal(w.connections["Replay Pipeline?"].main[1][0].node,"Respond to Shopify");
  assert.equal(w.connections["Shopify Replay Entry Trigger"].main[0][0].node,"Load Shopify Replay Row");
  assert.equal(w.connections["Replay Envelope Valid?"].main[0][0].node,"Replay Already Processed?");
  assert.equal(w.connections["Replay Already Processed?"].main[0][0].node,"Build Already Processed Replay Result");
  assert.equal(w.connections["Replay Already Processed?"].main[1][0].node,"Validate & Normalize");
  assert.match(findNode(w,"Build Shopify Replay Envelope").parameters.jsCode,/__replay_already_processed/);
});


test("public Shopify ingress always responds explicitly while replay subflow returns its own result", () => {
  const w = buildCandidate(source,map,pinned).workflow;
  const byName = new Map(w.nodes.map(n=>[n.name,n]));
  const response = byName.get("Respond to Shopify");
  assert.ok(response);
  assert.equal(w.nodes.filter(n=>n.type==="n8n-nodes-base.respondToWebhook").length,1);
  assert.equal(response.parameters.respondWith,"json");
  assert.match(response.parameters.responseBody,/__body/);
  assert.match(response.parameters.options.responseCode,/__http/);
  assert.equal(w.connections["Replay Pipeline?"].main[1][0].node,"Respond to Shopify");
  assert.equal(w.connections["Build Invalid Ingress Response"].main[0][0].node,"Respond to Shopify");
  assert.equal(w.connections["Replay Pipeline?"].main[0][0].node,"Renew Replay Lease Before Writes");
  assert.equal(w.connections["Respond to Shopify"],undefined);
  // Internal Execute Workflow callers consume these terminal result nodes;
  // they must not attempt to answer the original public webhook a second time.
  assert.equal(w.connections["Build Success Response"],undefined);
  assert.equal(w.connections["Build Deferred Payment Response"],undefined);
  assert.equal(w.connections["Build Already Processed Replay Result"],undefined);
  assert.match(byName.get("Build Success Response").parameters.assignments.assignments.find(a=>a.name==="mark_webhook_processed").value,/replay_context/);
  assert.equal(byName.get("Build Deferred Payment Response").parameters.assignments.assignments.find(a=>a.name==="deferred_payment_handoff").value,true);
});

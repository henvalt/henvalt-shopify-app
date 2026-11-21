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
  assert.equal(w.id,"00000000-0000-4000-8000-999999999999");
  assert.equal(w.name,"HENVALT_INGEST_CANDIDATE_NO_SEND");
  assert.equal(w.nodes.length,68);
  assert.equal(result.graphAudit.node_count,68);
  assert.equal(result.graphAudit.unique_node_ids,68);
  assert.equal(result.graphAudit.unique_node_names,68);
  assert.equal(result.audit.fenced_mutation_nodes,18);
  assert.equal(result.audit.active_workflow_modified,false);
  assert.ok(w.nodes.every(n=>!n.credentials && !n.webhookId));
  const webhook=w.nodes.find(n=>n.name==="Event Webhook");
  assert.equal(webhook.parameters.path,"henvalt/ingest-candidate-no-send");
  assert.equal(webhook.parameters.responseMode,"responseNode");
  assert.equal(w.nodes.find(n=>n.name==="Supabase Ingest RPC").parameters.url,
    "https://ocyplckdojdubyrsxcxa.supabase.co/rest/v1/rpc/receive_shopify_webhook_v1");
  assert.ok(w.nodes.some(n=>n.name==="Respond to Shopify"));
  assert.ok(w.nodes.some(n=>n.name==="Shopify Replay Entry Trigger"));
  assert.equal(w.connections["Is Trusted Replay?"].main[0][0].node,"Resolve Shopify Tenant");
  assert.equal(w.connections["Is Trusted Replay?"].main[1][0].node,"Supabase Ingest RPC");
  assert.equal(findNode(w,"Verify Shopify HMAC"),undefined);
  assert.equal(byName(w,"HMAC Verified?"),undefined);
  assert.match(byName(w,"Supabase Ingest RPC").parameters.jsonBody,/p_raw_body_base64/);
  assert.match(byName(w,"Supabase Ingest RPC").parameters.jsonBody,/p_hmac/);
  assert.ok(w.nodes.every(n=>!/(MailerSend|send email|provider send)/i.test(n.name)));
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
  assert.match(byName(w,"Build Shopify Replay Envelope").parameters.jsCode,/__replay_already_processed/);
});

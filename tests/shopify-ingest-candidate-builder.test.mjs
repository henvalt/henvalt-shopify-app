import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { buildCandidate } from "../n8n/shopify-ingest-candidate-builder.mjs";

const map = JSON.parse(readFileSync("n8n/shopify-ingest-replay-write-map.json", "utf8"));
const baseNode = (name,type,parameters={}) => ({id:"fixture-"+name,name,type,typeVersion:1,position:[0,0],parameters});
function fixture() {
  const nodes = [
    baseNode("Event Webhook","n8n-nodes-base.webhook",{responseMode:"onReceived",options:{rawBody:true}}),
    baseNode("Validate & Normalize","n8n-nodes-base.code",{jsCode:`const body = $json.body || {};
const source = "shopify";
const shopifyEventId = null;
const shopifyWebhookId = "delivery";
const eventId = body.event_id || shopifyEventId || shopifyWebhookId || body.id || null;
return {
  __valid: true,
  event: { event_id: eventId },
  ingest: { source_event_id: eventId }
};`}),
    baseNode("Engine Config","n8n-nodes-base.set",{includeOtherFields:true,assignments:{assignments:[]}}),
    baseNode("Resolve Shopify Tenant","n8n-nodes-base.httpRequest",{url:"https://db/rest/v1/rpc/resolve_shopify_tenant"}),
    baseNode("Bind Tenant Context","n8n-nodes-base.code",{jsCode:"out.__valid = norm.__valid === true && validTenant && !out.__tenant_lookup_error;"}),
    baseNode("Verify Shopify HMAC","n8n-nodes-base.httpRequest",{url:"https://db/rest/v1/rpc/verify_shopify_webhook_hmac"}),
    baseNode("HMAC Verified?","n8n-nodes-base.if",{}),
    baseNode("Is Valid","n8n-nodes-base.if",{}),
    baseNode("Supabase Ingest RPC","n8n-nodes-base.httpRequest",{url:"https://db/rest/v1/rpc/ingest_raw_webhook_v2",jsonBody:"={{ { p_tenant_id: $json.ingest.tenant_id } }}"}),
    baseNode("Classify Result","n8n-nodes-base.code",{jsCode:"return {};"}),
    baseNode("Should Process?","n8n-nodes-base.if",{}),
    baseNode("Mark Webhook Processed","n8n-nodes-base.httpRequest",{url:"https://db/rest/v1/rpc/mark_webhook_processed",jsonBody:"={{ { p_webhook_id: $json.webhook_id } }}"}),
    baseNode("Build Success Response","n8n-nodes-base.set",{assignments:{assignments:[{name:"__body",value:"={{ ({ status: 'processed', }) }}"}]}}),
    baseNode("Defer Payment Reconciliation","n8n-nodes-base.httpRequest",{url:"https://db/rest/v1/rpc/defer_payment_webhook_reconciliation",jsonBody:"={{ { p_webhook_id: $json.webhook_id, p_error: 'deferred' } }}"}),
    baseNode("Build Deferred Payment Response","n8n-nodes-base.set",{assignments:{assignments:[{name:"__body",value:"={{ ({ status: 'deferred_for_reconciliation', }) }}"}]}}),
    baseNode("Capture Error","n8n-nodes-base.code",{}),
    baseNode("Reject Invalid Event","n8n-nodes-base.stopAndError",{}),
  ];
  for (const item of map.replay_mutations) {
    if (nodes.some(n=>n.name===item.node)) continue;
    if (item.node === "Deactivate Shopify Connection") {
      nodes.push(baseNode(item.node,"n8n-nodes-base.postgres",{
        query:"SELECT henvalt.deactivate_shopify_connection_on_uninstall($1,$2,$3,$4)",
        options:{queryReplacement:"={{ [ 'tenant', 'shop', 'webhook', 'correlation' ] }}"}
      }));
    } else {
      nodes.push(baseNode(item.node,"n8n-nodes-base.httpRequest",{
        url:"https://db/rest/v1/rpc/"+item.current_rpc,
        jsonBody:"={{ { p_tenant_id: 'tenant', p_webhook_id: 'webhook' } }}"
      }));
    }
  }
  return {
    id:"VTpfGKNtu1CSQ4Rv",name:"HENVALT_INGEST",active:true,nodes,
    connections:{
      "Event Webhook":{main:[[{node:"Validate & Normalize",type:"main",index:0}]]},
      "Engine Config":{main:[[{node:"Verify Shopify HMAC",type:"main",index:0}]]},
      "HMAC Verified?":{main:[[{node:"Resolve Shopify Tenant",type:"main",index:0}],[]]},
      "Resolve Shopify Tenant":{main:[[{node:"Bind Tenant Context",type:"main",index:0}]]},
      "Bind Tenant Context":{main:[[{node:"Is Valid",type:"main",index:0}]]},
      "Is Valid":{main:[[{node:"Supabase Ingest RPC",type:"main",index:0}],[]]},
      "Supabase Ingest RPC":{main:[[{node:"Classify Result",type:"main",index:0}]]},
      "Classify Result":{main:[[{node:"Should Process?",type:"main",index:0}]]},
      "Should Process?":{main:[[],[]]},
      "Mark Webhook Processed":{main:[[{node:"Build Success Response",type:"main",index:0}]]},
      "Defer Payment Reconciliation":{main:[[{node:"Build Deferred Payment Response",type:"main",index:0}]]}
    }
  };
}

test("builder produces a separate inactive candidate with all 18 fenced mutation routes", () => {
  const result = buildCandidate(fixture(),map,"6368d539-708f-494a-8be8-b9601d0e8607");
  const workflow = result.workflow;
  assert.equal(result.audit.fenced_mutation_nodes,18);
  assert.equal(workflow.active,false);
  assert.equal(workflow.name,"HENVALT_INGEST_CANDIDATE_NO_SEND");
  assert.equal(workflow.meta.provider_sending_enabled,false);
  for (const entry of map.replay_mutations) {
    const node = workflow.nodes.find(n=>n.name===entry.node);
    if (entry.node === "Deactivate Shopify Connection") {
      assert.match(node.parameters.query,new RegExp(entry.fenced_rpc));
      assert.match(node.parameters.options.queryReplacement,/r\.job_id/);
    } else {
      assert.match(node.parameters.url,new RegExp(entry.fenced_rpc));
      assert.match(node.parameters.jsonBody,/p_job_id/);
    }
  }
});

test("candidate fixes Shopify delivery identity and preserves trusted replay context", () => {
  const workflow=buildCandidate(fixture(),map,"6368d539-708f-494a-8be8-b9601d0e8607").workflow;
  const normalizer=workflow.nodes.find(n=>n.name==="Validate & Normalize");
  assert.match(normalizer.parameters.jsCode,/source === 'shopify' \? \(shopifyWebhookId \|\| null\)/);
  assert.match(normalizer.parameters.jsCode,/replay_context: replayContext/);
  const bind=workflow.nodes.find(n=>n.name==="Bind Tenant Context");
  assert.match(bind.parameters.jsCode,/out.__replay_tenant_mismatch/);
});

test("public ingress waits for durable acknowledgement and never runs the business pipeline inline", () => {
  const workflow=buildCandidate(fixture(),map,"6368d539-708f-494a-8be8-b9601d0e8607").workflow;
  assert.equal(workflow.nodes.find(n=>n.name==="Event Webhook").parameters.responseMode,"responseNode");
  assert.match(workflow.nodes.find(n=>n.name==="Supabase Ingest RPC").parameters.url,/receive_shopify_webhook_v1/);
  assert.ok(workflow.nodes.some(n=>n.name==="Respond to Shopify"));
  assert.equal(workflow.connections["Replay Pipeline?"].main[0][0].node,"Should Process?");
  assert.equal(workflow.connections["Replay Pipeline?"].main[1][0].node,"Respond to Shopify");
  assert.equal(workflow.connections["Mark Webhook Processed"].main[0][0].node,"Processed Marker Confirmed?");
  assert.equal(workflow.connections["Defer Payment Reconciliation"].main[0][0].node,"Deferred Handoff Confirmed?");
});

test("builder rejects workflow or active-version drift", () => {
  assert.throws(()=>buildCandidate({...fixture(),id:"wrong"},map,"6368d539-708f-494a-8be8-b9601d0e8607"),/Wrong HENVALT_INGEST/);
  assert.throws(()=>buildCandidate(fixture(),map,"changed-version"),/version drift/);
});

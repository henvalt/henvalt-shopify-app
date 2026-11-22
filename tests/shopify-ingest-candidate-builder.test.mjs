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
  assert.equal(result.graphAudit.node_count,workflow.nodes.length);
  assert.equal(result.graphAudit.unique_node_ids,workflow.nodes.length);
  assert.equal(result.graphAudit.unique_node_names,workflow.nodes.length);
  assert.equal(workflow.active,false);
  assert.equal(workflow.name,"HENVALT_INGEST_CANDIDATE_NO_SEND");
  assert.equal(workflow.id,"00000000-0000-4000-8000-999999999999");
  assert.ok(workflow.nodes.every(n=>n.id!==workflow.id));
  assert.equal(workflow.nodes.find(n=>n.name==="Event Webhook").parameters.path,"henvalt/ingest-candidate-no-send");
  assert.equal(workflow.nodes.find(n=>n.name==="Event Webhook").webhookId,undefined);
  assert.ok(workflow.nodes.every(n=>n.credentials===undefined));
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

test("fenced lease tuple cannot be overridden by original RPC arguments", () => {
  const workflow = buildCandidate(fixture(),map,"6368d539-708f-494a-8be8-b9601d0e8607").workflow;
  for (const entry of map.replay_mutations) {
    if (entry.node === "Deactivate Shopify Connection") continue;
    const node = workflow.nodes.find(n => n.name === entry.node);
    const body = node.parameters.jsonBody;
    assert.ok(body.includes("return { ...p, p_job_id: r.job_id, p_worker_id: r.worker_id, p_lease_id: r.lease_id"));
    assert.equal(body.includes("p_lease_id: r.lease_id, ...p"), false);
  }
});

test("per-item replay Code nodes return explicit n8n item wrappers", () => {
  const workflow = buildCandidate(fixture(),map,"6368d539-708f-494a-8be8-b9601d0e8607").workflow;
  const envelope = workflow.nodes.find(n => n.name === "Build Shopify Replay Envelope");
  const renewal = workflow.nodes.find(n => n.name === "Confirm Replay Lease Renewal");
  assert.equal(envelope.parameters.mode, "runOnceForEachItem");
  assert.equal(renewal.parameters.mode, "runOnceForEachItem");
  assert.ok(envelope.parameters.jsCode.includes("return { json: {"));
  assert.ok(renewal.parameters.jsCode.includes("return { json: {"));
  assert.ok(envelope.parameters.jsCode.includes("if (errors.length) return { json: {"));
  assert.ok(envelope.parameters.jsCode.includes("if (alreadyProcessed) return { json: {"));
});

test("generated replay envelope Code node executes valid, processed and invalid rows", () => {
  const workflow = buildCandidate(fixture(),map,"6368d539-708f-494a-8be8-b9601d0e8607").workflow;
  const node = workflow.nodes.find(n => n.name === "Build Shopify Replay Envelope");
  const job = "11111111-1111-4111-8111-111111111111";
  const lease = "22222222-2222-4222-8222-222222222222";
  const webhook = "33333333-3333-4333-8333-333333333333";
  const tenant = "44444444-4444-4444-8444-444444444444";
  const claim = {job_id:job,worker_id:"recovery-worker",lease_id:lease};
  const row = {
    job_id:job,webhook_id:webhook,tenant_id:tenant,source_event_id:"delivery-123",
    topic:"checkouts/update",payload:{id:42,email:"buyer@example.test"},
    metadata:{ingress_hmac_verified:true,shop_domain:"demo.myshopify.com",shopify_webhook_id:"delivery-123"},
    processing_status:"PROCESSING",webhook_processed:false,
    lease_expires_at:"2099-11-21T23:00:00.000Z",correlation_id:null
  };
  const run = (input) => new Function("$","$json",node.parameters.jsCode)(
    (name) => { assert.equal(name,"Shopify Replay Entry Trigger"); return {item:{json:claim}}; },
    input
  );
  const valid = run({statusCode:200,body:row});
  assert.equal(valid.json.body.event_id,"delivery-123");
  assert.equal(valid.json.headers["x-shopify-webhook-id"],"delivery-123");
  assert.equal(valid.json.replay_context.tenant_id,tenant);
  assert.equal(valid.json.replay_context.lease_id,lease);
  const processed = run({statusCode:200,body:{...row,webhook_processed:true,processing_status:"PROCESSED"}});
  assert.equal(processed.json.mark_webhook_processed,true);
  assert.equal(processed.json.replay_context.webhook_id,webhook);
  const invalid = run({statusCode:200,body:{...row,metadata:{...row.metadata,ingress_hmac_verified:false}}});
  assert.equal(invalid.json.__replay_invalid,true);
  assert.match(invalid.json.__replay_reason,/INGRESS_NOT_AUTHENTICATED/);
});

test("generated lease renewal Code node preserves the exact trusted context", () => {
  const workflow = buildCandidate(fixture(),map,"6368d539-708f-494a-8be8-b9601d0e8607").workflow;
  const node = workflow.nodes.find(n => n.name === "Confirm Replay Lease Renewal");
  const prior = {__proceed:true,__replay:true,replay_context:{job_id:"job"}};
  const context = {job_id:"job",worker_id:"worker",lease_id:"lease",lease_expires_at:"old"};
  const result = new Function("$","$json",node.parameters.jsCode)(
    (name) => name === "Classify Result"
      ? {item:{json:prior}}
      : {item:{json:{replay_context:context}}},
    {statusCode:200,body:"2099-11-21T23:00:00.000Z"}
  );
  assert.deepEqual(result.json.replay_context,{...context,lease_expires_at:"2099-11-21T23:00:00.000Z"});
  assert.equal(result.json.__proceed,true);
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
  assert.equal(workflow.connections["Replay Pipeline?"].main[0][0].node,"Renew Replay Lease Before Writes");
  assert.match(workflow.nodes.find(n=>n.name==="Renew Replay Lease Before Writes").parameters.jsonBody,/p_lease_seconds: 180/);
  assert.equal(workflow.connections["Confirm Replay Lease Renewal"].main[0][0].node,"Should Process?");
  assert.equal(workflow.connections["Replay Pipeline?"].main[1][0].node,"Respond to Shopify");
  assert.equal(workflow.connections["Mark Webhook Processed"].main[0][0].node,"Processed Marker Confirmed?");
  assert.equal(workflow.connections["Defer Payment Reconciliation"].main[0][0].node,"Deferred Handoff Confirmed?");
  const success = workflow.nodes.find(n=>n.name==="Build Success Response");
  assert.ok(success.parameters.assignments.assignments.some(a=>a.name==="mark_webhook_processed"));
  const deferred = workflow.nodes.find(n=>n.name==="Build Deferred Payment Response");
  assert.ok(deferred.parameters.assignments.assignments.some(a=>a.name==="deferred_payment_handoff"));
  assert.equal(workflow.connections["Is Valid"].main[1][0].node,"Is Rejected Replay?");
  assert.equal(workflow.connections["Should Process?"].main[1][0].node,"Stop Replay Not Proceedable");
  assert.match(workflow.nodes.find(n=>n.name==="Build Invalid Ingress Response").parameters.assignments.assignments[0].value,/__tenant_lookup_error \? 503/);
});

test("builder rejects workflow or active-version drift", () => {
  assert.throws(()=>buildCandidate({...fixture(),id:"wrong"},map,"6368d539-708f-494a-8be8-b9601d0e8607"),/Wrong HENVALT_INGEST/);
  assert.throws(()=>buildCandidate(fixture(),map,"changed-version"),/version drift/);
});

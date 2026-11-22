import { readFileSync, writeFileSync } from "node:fs";

const REQUIRED_WORKFLOW_ID = "VTpfGKNtu1CSQ4Rv";
const REQUIRED_ACTIVE_VERSION = "6368d539-708f-494a-8be8-b9601d0e8607";
const REQUIRED_WORKFLOWS = 3;
const MAP_PATH = "n8n/shopify-ingest-replay-write-map.json";

function expressionBody(source) {
  if (typeof source !== "string") throw new Error("RPC JSON body is missing");
  const match = source.match(/^=\{\{([\s\S]*)\}\}$/);
  if (!match) throw new Error("RPC JSON body is not a single n8n expression");
  return match[1].trim();
}
function nodeByName(workflow, name) {
  const node = workflow.nodes.find((entry) => entry.name === name);
  if (!node) throw new Error("Expected active node missing: " + name);
  return node;
}
function addNode(workflow, node) {
  if (workflow.nodes.some((entry) => entry.name === node.name)) throw new Error("Candidate node already exists: " + node.name);
  workflow.nodes.push(node);
}
function connect(workflow, from, to, output = 0) {
  workflow.connections[from] ||= { main: [] };
  workflow.connections[from].main[output] ||= [];
  workflow.connections[from].main[output].push({ node: to, type: "main", index: 0 });
}
let candidateNodeCounter = 1;
function id() { return "00000000-0000-4000-8000-" + String(candidateNodeCounter++).padStart(12,"0"); }
function fencedBody(source, nodeName) {
  const original = expressionBody(source);
  const forceConstantError = nodeName === "Mark Webhook Failed" || nodeName === "Defer Payment Reconciliation";
  return "={{ (() => { const p = (" + original + "); const r = $('Validate & Normalize').item.json.replay_context; if (!r) return p; return { ...p, p_job_id: r.job_id, p_worker_id: r.worker_id, p_lease_id: r.lease_id" +
    (forceConstantError ? ", p_error: 'SHOPIFY_REPLAY_PROCESSING_FAILED'" : "") +
    " }; })() }}";
}
function addFencing(workflow, map) {
  let changed = 0;
  for (const entry of map.replay_mutations) {
    const node = nodeByName(workflow, entry.node);
    if (node.type === "n8n-nodes-base.httpRequest") {
      if (!node.parameters.url || !node.parameters.url.includes("/rpc/" + entry.current_rpc)) {
        throw new Error("Unexpected RPC URL for " + entry.node);
      }
      node.parameters.url = "={{ 'https://ocyplckdojdubyrsxcxa.supabase.co/rest/v1/rpc/' + ($('Validate & Normalize').item.json.replay_context ? '" +
        entry.fenced_rpc + "' : '" + entry.current_rpc + "') }}";
      node.parameters.jsonBody = fencedBody(node.parameters.jsonBody, entry.node);
      changed++;
    } else if (node.type === "n8n-nodes-base.postgres" && entry.node === "Deactivate Shopify Connection") {
      const args = node.parameters.options?.queryReplacement;
      if (typeof args !== "string") throw new Error("Postgres query args missing for " + entry.node);
      const original = expressionBody(args);
      node.parameters.query = "={{ $('Validate & Normalize').item.json.replay_context ? 'SELECT henvalt." +
        entry.fenced_rpc + "($1,$2,$3,$4,$5,$6,$7) AS result' : 'SELECT henvalt." +
        entry.current_rpc + "($1,$2,$3,$4) AS result' }}";
      node.parameters.options.queryReplacement = "={{ (() => { const a = (" + original +
        "); const r = $('Validate & Normalize').item.json.replay_context; return r ? [r.job_id,r.worker_id,r.lease_id,...a] : a; })() }}";
      changed++;
    } else {
      throw new Error("Unsupported mutation node type for " + entry.node + ": " + node.type);
    }
  }
  if (changed !== 18) throw new Error("Expected exactly 18 fenced mutation nodes, changed " + changed);
  return changed;
}
function preserveReplayContext(normalizer) {
  let code = normalizer.parameters.jsCode;
  if (!code.includes("const replayContext = $json.replay_context || null;")) {
    code = code.replace("const body = $json.body || {};", "const body = $json.body || {};\nconst replayContext = $json.replay_context || null;");
  }
  if (!code.includes("replay_context: replayContext")) {
    code = code.replace("return {\n  __valid:", "return {\n  replay_context: replayContext,\n  __valid:");
  }
  const eventIdLine = "const eventId = body.event_id || shopifyEventId || shopifyWebhookId || body.id || null;";
  if (code.includes(eventIdLine)) code = code.replace(eventIdLine, "const eventId = source === 'shopify' ? (shopifyWebhookId || null) : (body.event_id || shopifyEventId || shopifyWebhookId || body.id || null);");
  if (!code.includes("const eventId = source === 'shopify' ? (shopifyWebhookId || null)")) throw new Error("Could not enforce Shopify delivery ID as event identity");
  if (!code.includes("replay_context: replayContext")) throw new Error("Could not preserve replay context in normalizer");
  normalizer.parameters.jsCode = code;
  if (!code.includes("replay_context: replayContext")) throw new Error("Could not preserve replay context in normalizer");
  normalizer.parameters.jsCode = code;
}
function addTenantReplayGuard(bindNode) {
  let code = bindNode.parameters.jsCode;
  const needle = "out.__valid = norm.__valid === true && validTenant && !out.__tenant_lookup_error;";
  if (code.includes(needle)) {
    code = code.replace(needle, "out.__replay_tenant_mismatch = !!(norm.replay_context && norm.replay_context.tenant_id !== tenantId);\nout.__valid = norm.__valid === true && validTenant && !out.__tenant_lookup_error && !out.__replay_tenant_mismatch;");
  }
  if (!code.includes("out.__replay_tenant_mismatch")) throw new Error("Could not add replay tenant equality guard");
  bindNode.parameters.jsCode = code;
}
function replaceClassifier(node) {
  node.parameters.jsCode = `const norm = $("Validate & Normalize").item.json;
const corr = norm.correlation_id;
const eventId = norm.event?.event_id || null;
const replay = norm.replay_context || null;
const isUuid = (value) => typeof value === "string" && /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(value);

// The replay path enters only after the lease-fenced loader and tenant equality guard.
if (replay) {
  const bound = $("Bind Tenant Context").item.json;\n  if (bound.__replay_tenant_mismatch || bound.ingest?.tenant_id !== replay.tenant_id) {
    return { __proceed: false, __replay: true, __http: 503, __body: { status: "replay_tenant_mismatch" } };
  }
  return {
    __proceed: true, __replay: true, __webhook_id: replay.webhook_id,
    __http: 200, __body: { status: "replay_processing", webhook_id: replay.webhook_id, correlation_id: corr },
    replay_context: replay
  };
}

// Public ingress must use the atomic receive_shopify_webhook_v1 result.
// Never translate a generic 409 into a successful duplicate.
const resp = $json || {};
if (resp.error !== undefined || resp.statusCode === undefined) {
  return { __proceed: false, __replay: false, __http: 503, __body: { status: "temporarily_unavailable", correlation_id: corr } };
}
const raw = resp.body;
const row = Array.isArray(raw) ? (raw[0] || {}) : (raw || {});
if (Number(row.http_status) !== 200 || !isUuid(row.webhook_id)) {
  const status = [401,404,422,503].includes(Number(row.http_status)) ? Number(row.http_status) : 503;
  return { __proceed: false, __replay: false, __http: status, __body: { status: row.result_status || "temporarily_unavailable", correlation_id: row.correlation_id || corr } };
}
const state = String(row.processing_status || "").toUpperCase();
if (row.result_status === "duplicate" && state === "PROCESSED") {
  return { __proceed: false, __replay: false, __http: 200, __body: { status: "duplicate", webhook_id: row.webhook_id, correlation_id: row.correlation_id || corr } };
}
if (["accepted","replay_accepted"].includes(row.result_status) &&
    isUuid(row.replay_job_id) && ["QUEUED","CLAIMED","RUNNING","RETRY_WAIT"].includes(String(row.replay_job_status || "").toUpperCase())) {
  return { __proceed: false, __replay: false, __http: 200, __body: { status: row.result_status, webhook_id: row.webhook_id, replay_job_id: row.replay_job_id, correlation_id: row.correlation_id || corr } };
}
return { __proceed: false, __replay: false, __http: 503, __body: { status: "durable_replay_job_not_confirmed", correlation_id: corr } };`;
}
function createNode(name, type, parameters, position, typeVersion = 1) {
  return { id: id(name.toLowerCase().replace(/[^a-z0-9]+/g,"-")), name, type, typeVersion, position, parameters };
}
function addReplayAndIngressNodes(workflow) {
  const event = nodeByName(workflow, "Event Webhook");
  const normalizer = nodeByName(workflow, "Validate & Normalize");
  const engine = nodeByName(workflow, "Engine Config");
  const bind = nodeByName(workflow, "Bind Tenant Context");
  const valid = nodeByName(workflow, "Is Valid");
  const ingest = nodeByName(workflow, "Supabase Ingest RPC");
  const classifier = nodeByName(workflow, "Classify Result");
  const processed = nodeByName(workflow, "Mark Webhook Processed");
  const defer = nodeByName(workflow, "Defer Payment Reconciliation");
  const successResponse = nodeByName(workflow, "Build Success Response");
  const deferredResponse = nodeByName(workflow, "Build Deferred Payment Response");

  event.parameters.responseMode = "responseNode";
  preserveReplayContext(normalizer);
  addTenantReplayGuard(bind);
  replaceClassifier(classifier);
  const successAssignment = successResponse.parameters.assignments.assignments.find((a) => a.name === "__body");
  if (!successAssignment || typeof successAssignment.value !== "string") throw new Error("Success response body assignment missing");
  successAssignment.value = successAssignment.value.replace("status: 'processed',", "status: 'processed',");
  if (!successResponse.parameters.assignments.assignments.some((a) => a.name === "mark_webhook_processed")) successResponse.parameters.assignments.assignments.push({id:"replay-processed-flag",name:"mark_webhook_processed",type:"boolean",value:"={{ !!$('Validate & Normalize').item.json.replay_context }}"});
  const deferredAssignment = deferredResponse.parameters.assignments.assignments.find((a) => a.name === "__body");
  if (!deferredAssignment || typeof deferredAssignment.value !== "string") throw new Error("Deferred response body assignment missing");
  deferredAssignment.value = deferredAssignment.value.replace("status: 'deferred_for_reconciliation',", "status: 'deferred_for_reconciliation',");
  if (!deferredResponse.parameters.assignments.assignments.some((a) => a.name === "deferred_payment_handoff")) deferredResponse.parameters.assignments.assignments.push({id:"deferred-handoff-flag",name:"deferred_payment_handoff",type:"boolean",value:true});

  // Atomic public ingress: verify + resolve again inside one database transaction,
  // then persist the webhook and replay job before responding to Shopify.
  ingest.parameters.url = "https://ocyplckdojdubyrsxcxa.supabase.co/rest/v1/rpc/receive_shopify_webhook_v1";
  ingest.parameters.jsonBody = "={{ { p_shop_domain: $json.verification.shop_domain, p_topic: $json.ingest.topic, p_delivery_id: $json.ingest.source_event_id, p_hmac: $json.verification.hmac_sha256, p_raw_body_base64: $json.verification.raw_body_base64, p_payload: $json.ingest.payload, p_metadata: $json.ingest.metadata } }}";

  // Only the internal replay trigger can reach this path. It never accepts a body
  // or tenant ID from the public webhook request.
  const trigger = createNode("Shopify Replay Entry Trigger","n8n-nodes-base.executeWorkflowTrigger",{
    inputSource:"workflowInputs",
    workflowInputs:{values:[
      {name:"job_id",type:"string"},
      {name:"worker_id",type:"string"},
      {name:"lease_id",type:"string"}
    ]},
    returnOutput:"lastRunOnly"
  },[-1100,900],1.1);
  trigger.isTrigger = true;
  const loader = createNode("Load Shopify Replay Row","n8n-nodes-base.httpRequest",{
    method:"POST",url:"https://ocyplckdojdubyrsxcxa.supabase.co/rest/v1/rpc/load_shopify_webhook_replay_job",
    authentication:"predefinedCredentialType",nodeCredentialType:"supabaseApi",sendHeaders:true,
    headerParameters:{parameters:[{name:"Content-Type",value:"application/json"},{name:"Content-Profile",value:"henvalt"}]},
    sendBody:true,specifyBody:"json",
    jsonBody:"={{ { p_job_id: $json.job_id, p_worker_id: $json.worker_id, p_lease_id: $json.lease_id } }}",
    options:{response:{response:{fullResponse:true,neverError:false,responseFormat:"json"}},timeout:15000}
  },[-880,900],4.2);
  const envelope = createNode("Build Shopify Replay Envelope","n8n-nodes-base.code",{
    mode:"runOnceForEachItem",
    jsCode:`const claim = $("Shopify Replay Entry Trigger").item.json;
const response = $json || {};
const rowValue = response.body;
const row = Array.isArray(rowValue) ? rowValue[0] : rowValue;
const uuid = (v) => typeof v === "string" && /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(v);
const errors = [];
if (response.error || response.statusCode < 200 || response.statusCode >= 300 || !row || typeof row !== "object") errors.push("LOAD_FAILED");
if (!uuid(claim.job_id) || claim.job_id !== row?.job_id) errors.push("JOB_ID_MISMATCH");
if (typeof claim.worker_id !== "string" || !claim.worker_id.trim()) errors.push("WORKER_MISSING");
if (!uuid(claim.lease_id) || !uuid(row?.webhook_id) || !uuid(row?.tenant_id)) errors.push("IDENTITY_INVALID");
if (!row?.payload || typeof row.payload !== "object" || Array.isArray(row.payload)) errors.push("PAYLOAD_INVALID");
if (row?.metadata?.ingress_hmac_verified !== true) errors.push("INGRESS_NOT_AUTHENTICATED");
const shop = typeof row?.metadata?.shop_domain === "string" ? row.metadata.shop_domain.trim().toLowerCase() : "";
if (!/^[a-z0-9][a-z0-9-]*\\.myshopify\\.com$/.test(shop)) errors.push("SHOP_INVALID");
if (typeof row?.source_event_id !== "string" || !row.source_event_id.trim() || row?.metadata?.shopify_webhook_id !== row?.source_event_id) errors.push("DELIVERY_ID_INVALID");
if (typeof row?.topic !== "string" || !row.topic.trim()) errors.push("TOPIC_INVALID");
if (row?.correlation_id != null && !uuid(row.correlation_id)) errors.push("CORRELATION_ID_INVALID");
if (typeof row?.lease_expires_at !== "string" || !Number.isFinite(Date.parse(row.lease_expires_at)) || Date.parse(row.lease_expires_at) <= Date.now()) errors.push("LEASE_EXPIRED");
const alreadyProcessed = row?.webhook_processed === true || String(row?.processing_status || "").toUpperCase() === "PROCESSED";
if (!alreadyProcessed && !["PROCESSING","FAILED"].includes(String(row?.processing_status || "").toUpperCase())) errors.push("WEBHOOK_STATE_NOT_REPLAYABLE");
if (errors.length) return { json: { __replay_invalid: true, __replay_reason: errors.join(",") } };
const replayContext = {
  job_id: claim.job_id, worker_id: claim.worker_id.trim(), lease_id: claim.lease_id,
  lease_expires_at: row.lease_expires_at, tenant_id: row.tenant_id,
  webhook_id: row.webhook_id, correlation_id: row.correlation_id || null,
  source_event_id: row.source_event_id, ingress_hmac_verified: true
};
if (alreadyProcessed) return { json: { __replay_already_processed: true, replay_context: replayContext, mark_webhook_processed: true } };
const body = { ...row.payload, event_id: row.source_event_id, correlation_id: row.correlation_id || undefined };
const headers = {
  "x-shopify-shop-domain": shop,
  "x-shopify-topic": row.topic,
  "x-shopify-webhook-id": row.source_event_id
};
if (typeof row.metadata.shopify_api_version === "string") headers["x-shopify-api-version"] = row.metadata.shopify_api_version;
if (typeof row.metadata.shopify_triggered_at === "string") headers["x-shopify-triggered-at"] = row.metadata.shopify_triggered_at;
return { json: {
  body, headers, query: {},
  replay_context: {
    job_id: claim.job_id, worker_id: claim.worker_id.trim(), lease_id: claim.lease_id,
    lease_expires_at: row.lease_expires_at, tenant_id: row.tenant_id,
    webhook_id: row.webhook_id, correlation_id: row.correlation_id || null,
    source_event_id: row.source_event_id, ingress_hmac_verified: true
  }
} };`
  },[-660,900],2);
  const envelopeValid = createNode("Replay Envelope Valid?","n8n-nodes-base.if",{
    conditions:{options:{caseSensitive:true,leftValue:"",typeValidation:"strict",version:2},combinator:"and",conditions:[{id:"replay-envelope-valid",leftValue:"={{ $json.replay_context !== undefined && !$json.__replay_invalid }}",rightValue:true,operator:{type:"boolean",operation:"true",singleValue:true}}]},options:{}
  },[-440,900],2.2);
  const alreadyProcessed = createNode("Replay Already Processed?","n8n-nodes-base.if",{
    conditions:{options:{caseSensitive:true,leftValue:"",typeValidation:"strict",version:2},combinator:"and",conditions:[{id:"replay-already-processed",leftValue:"={{ $json.__replay_already_processed === true }}",rightValue:true,operator:{type:"boolean",operation:"true",singleValue:true}}]},options:{}
  },[-220,900],2.2);
  const alreadyProcessedResult = createNode("Build Already Processed Replay Result","n8n-nodes-base.set",{
    mode:"manual",assignments:{assignments:[
      {id:"already-processed-flag",name:"mark_webhook_processed",type:"boolean",value:true},
      {id:"already-processed-status",name:"replay_status",type:"string",value:"already_processed"}
    ]},includeOtherFields:true,options:{}
  },[0,760],3.4);
  const invalidReplay = createNode("Stop Invalid Replay Envelope","n8n-nodes-base.stopAndError",{errorMessage:"=Shopify replay envelope rejected: {{ $json.__replay_reason || 'invalid lease-bound stored event' }}"},[-220,1120],1);
  const trustedReplay = createNode("Is Trusted Replay?","n8n-nodes-base.if",{
    conditions:{options:{caseSensitive:true,leftValue:"",typeValidation:"strict",version:2},combinator:"and",conditions:[{id:"trusted-replay",leftValue:"={{ !!$('Validate & Normalize').item.json.replay_context }}",rightValue:true,operator:{type:"boolean",operation:"true",singleValue:true}}]},options:{}
  },[180,600],2.2);
  const replayOrIngress = createNode("Is Replay Entry?","n8n-nodes-base.if",{
    conditions:{options:{caseSensitive:true,leftValue:"",typeValidation:"strict",version:2},combinator:"and",conditions:[{id:"is-replay-entry",leftValue:"={{ !!$('Validate & Normalize').item.json.replay_context }}",rightValue:true,operator:{type:"boolean",operation:"true",singleValue:true}}]},options:{}
  },[1120,600],2.2);
  const renewLease = createNode("Renew Replay Lease Before Writes","n8n-nodes-base.httpRequest",{
    method:"POST",url:"https://ocyplckdojdubyrsxcxa.supabase.co/rest/v1/rpc/renew_shopify_replay_lease",
    authentication:"predefinedCredentialType",nodeCredentialType:"supabaseApi",sendHeaders:true,
    headerParameters:{parameters:[{name:"Content-Type",value:"application/json"},{name:"Content-Profile",value:"henvalt"}]},
    sendBody:true,specifyBody:"json",
    jsonBody:"={{ { p_job_id: $('Validate & Normalize').item.json.replay_context.job_id, p_worker_id: $('Validate & Normalize').item.json.replay_context.worker_id, p_lease_id: $('Validate & Normalize').item.json.replay_context.lease_id, p_lease_seconds: 180 } }}",
    options:{response:{response:{fullResponse:true,neverError:false,responseFormat:"json"}},timeout:15000}
  },[672,880],4.2);
  const confirmRenewal = createNode("Confirm Replay Lease Renewal","n8n-nodes-base.code",{
    mode:"runOnceForEachItem",jsCode:`const response = $json || {};
const prior = $("Classify Result").item.json;
const context = $("Validate & Normalize").item.json.replay_context;
if (response.error || response.statusCode < 200 || response.statusCode >= 300 || !response.body) {
  throw new Error("SHOPIFY_REPLAY_LEASE_RENEWAL_NOT_CONFIRMED");
}
return { json: { ...prior, replay_context: { ...context, lease_expires_at: response.body } } };`
  },[896,880],2);
  const replayPipeline = createNode("Replay Pipeline?","n8n-nodes-base.if",{
    conditions:{options:{caseSensitive:true,leftValue:"",typeValidation:"strict",version:2},combinator:"and",conditions:[{id:"replay-pipeline",leftValue:"={{ $json.__replay === true }}",rightValue:true,operator:{type:"boolean",operation:"true",singleValue:true}}]},options:{}
  },[448,0],2.2);
  const respond = createNode("Respond to Shopify","n8n-nodes-base.respondToWebhook",{
    respondWith:"json",responseBody:"={{ $json.__body || { status: 'temporarily_unavailable' } }}",
    options:{responseCode:"={{ $json.__http || 503 }}"}
  },[672,-200],1.4);
  const invalidReplayContext = createNode("Is Rejected Replay?","n8n-nodes-base.if",{
    conditions:{options:{caseSensitive:true,leftValue:"",typeValidation:"strict",version:2},combinator:"and",conditions:[{id:"invalid-is-replay",leftValue:"={{ !!$json.replay_context }}",rightValue:true,operator:{type:"boolean",operation:"true",singleValue:true}}]},options:{}
  },[224,320],2.2);
  const invalidResponse = createNode("Build Invalid Ingress Response","n8n-nodes-base.set",{
    mode:"manual",assignments:{assignments:[
      {id:"invalid-http",name:"__http",type:"number",value:"={{ $json.__tenant_lookup_error ? 503 : ($json.__tenant_mapping_missing ? 404 : 422) }}"},
      {id:"invalid-body",name:"__body",type:"object",value:"={{ { status: $json.__tenant_lookup_error ? 'temporarily_unavailable' : 'malformed_event', correlation_id: $json.correlation_id } }}"}
    ]},includeOtherFields:true,options:{}
  },[448,320],3.4);
  const processedGate = createNode("Processed Marker Confirmed?","n8n-nodes-base.if",{
    conditions:{options:{caseSensitive:true,leftValue:"",typeValidation:"strict",version:2},combinator:"and",conditions:[{id:"processed-marker-true",leftValue:"={{ $json.body === true || $json.body === 'true' }}",rightValue:true,operator:{type:"boolean",operation:"true",singleValue:true}}]},options:{}
  },[4160,768],2.2);
  const deferredGate = createNode("Deferred Handoff Confirmed?","n8n-nodes-base.if",{
    conditions:{options:{caseSensitive:true,leftValue:"",typeValidation:"strict",version:2},combinator:"and",conditions:[{id:"deferred-handoff-true",leftValue:"={{ $json.body === true || $json.body === 'true' }}",rightValue:true,operator:{type:"boolean",operation:"true",singleValue:true}}]},options:{}
  },[-336,1008],2.2);
  const stopMarker = createNode("Stop Unconfirmed Processed Marker","n8n-nodes-base.stopAndError",{errorMessage:"HENVALT replay processed marker was not confirmed; lease must be retried."},[4384,992],1);
  const stopNotProceedable = createNode("Stop Replay Not Proceedable","n8n-nodes-base.stopAndError",{errorMessage:"HENVALT replay did not pass the proceed guard; retry through the lease worker."},[1120,1120],1);

  // The replay route bypasses only the second HMAC RPC. It still resolves the shop
  // and Bind Tenant Context enforces equality with the loader's tenant_id.
  workflow.connections["Engine Config"] = {main:[[{node:"Is Trusted Replay?",type:"main",index:0}]]};
  workflow.connections["Is Trusted Replay?"] = {main:[
    [{node:"Resolve Shopify Tenant",type:"main",index:0}],
    [{node:"Supabase Ingest RPC",type:"main",index:0}]
  ]};
  workflow.connections["Bind Tenant Context"].main = [[{node:"Is Valid",type:"main",index:0}]];
  workflow.connections["Is Valid"].main[0] = [{node:"Is Replay Entry?",type:"main",index:0}];
  workflow.connections["Is Valid"].main[1] = [{node:"Is Rejected Replay?",type:"main",index:0}];
  workflow.connections["Is Replay Entry?"] = {main:[
    [{node:"Classify Result",type:"main",index:0}],
    [{node:"Supabase Ingest RPC",type:"main",index:0}]
  ]};
  workflow.connections["Supabase Ingest RPC"].main = [[{node:"Classify Result",type:"main",index:0}],[{node:"Classify Result",type:"main",index:0}]];
  workflow.connections["Classify Result"].main = [[{node:"Replay Pipeline?",type:"main",index:0}]];
  workflow.connections["Replay Pipeline?"] = {main:[
    [{node:"Renew Replay Lease Before Writes",type:"main",index:0}],
    [{node:"Respond to Shopify",type:"main",index:0}]
  ]};
  workflow.connections["Renew Replay Lease Before Writes"] = {main:[[{node:"Confirm Replay Lease Renewal",type:"main",index:0}]]};
  workflow.connections["Confirm Replay Lease Renewal"] = {main:[[{node:"Should Process?",type:"main",index:0}]]};
  workflow.connections["Should Process?"].main[1] = [{node:"Stop Replay Not Proceedable",type:"main",index:0}];
  workflow.connections["Mark Webhook Processed"].main = [[{node:"Processed Marker Confirmed?",type:"main",index:0}]];
  workflow.connections["Processed Marker Confirmed?"] = {main:[[{node:"Build Success Response",type:"main",index:0}],[{node:"Stop Unconfirmed Processed Marker",type:"main",index:0}]]};
  workflow.connections["Defer Payment Reconciliation"].main = [[{node:"Deferred Handoff Confirmed?",type:"main",index:0}],[{node:"Capture Error",type:"main",index:0}]];
  workflow.connections["Deferred Handoff Confirmed?"] = {main:[[{node:"Build Deferred Payment Response",type:"main",index:0}],[{node:"Capture Error",type:"main",index:0}]]};
  workflow.connections["Is Rejected Replay?"] = {main:[[{node:"Stop Invalid Replay Envelope",type:"main",index:0}],[{node:"Build Invalid Ingress Response",type:"main",index:0}]]};
  workflow.connections["Build Invalid Ingress Response"] = {main:[[{node:"Respond to Shopify",type:"main",index:0}]]};
  workflow.connections["Replay Envelope Valid?"] = {main:[
    [{node:"Replay Already Processed?",type:"main",index:0}],
    [{node:"Stop Invalid Replay Envelope",type:"main",index:0}]
  ]};
  workflow.connections["Replay Already Processed?"] = {main:[
    [{node:"Build Already Processed Replay Result",type:"main",index:0}],
    [{node:"Validate & Normalize",type:"main",index:0}]
  ]};
  workflow.connections["Shopify Replay Entry Trigger"] = {main:[[{node:"Load Shopify Replay Row",type:"main",index:0}]]};
  workflow.connections["Load Shopify Replay Row"] = {main:[[{node:"Build Shopify Replay Envelope",type:"main",index:0}]]};
  workflow.connections["Build Shopify Replay Envelope"] = {main:[[{node:"Replay Envelope Valid?",type:"main",index:0}]]};
  workflow.connections["Event Webhook"].main = [[{node:"Validate & Normalize",type:"main",index:0}]];
  workflow.connections["Event Webhook"].main[0] = [{node:"Validate & Normalize",type:"main",index:0}];

  // The atomic ingress RPC now owns HMAC verification and tenant resolution for
  // public requests. Keep tenant lookup only on the trusted internal replay branch.
  workflow.nodes = workflow.nodes.filter((node) => !["Verify Shopify HMAC","HMAC Verified?"].includes(node.name));
  delete workflow.connections["Verify Shopify HMAC"];
  delete workflow.connections["HMAC Verified?"];
  addNode(workflow,trigger); addNode(workflow,loader); addNode(workflow,envelope); addNode(workflow,envelopeValid);
  addNode(workflow,invalidReplay); addNode(workflow,alreadyProcessed); addNode(workflow,alreadyProcessedResult); addNode(workflow,trustedReplay); addNode(workflow,replayOrIngress);
  addNode(workflow,invalidReplayContext);
  addNode(workflow,replayPipeline); addNode(workflow,respond); addNode(workflow,invalidResponse);
  addNode(workflow,renewLease); addNode(workflow,confirmRenewal);
  addNode(workflow,processedGate); addNode(workflow,deferredGate); addNode(workflow,stopMarker);
  addNode(workflow,stopNotProceedable);

  // n8n graph connections support multiple upstream nodes. Append replay envelope
  // as an additional source for the existing normalizer.
  workflow.connections["Build Shopify Replay Envelope"] = {main:[[{node:"Replay Envelope Valid?",type:"main",index:0}]]};
  workflow.connections["Replay Envelope Valid?"] = {main:[
    [{node:"Replay Already Processed?",type:"main",index:0}],
    [{node:"Stop Invalid Replay Envelope",type:"main",index:0}]
  ]};
  workflow.connections["Replay Already Processed?"] = {main:[
    [{node:"Build Already Processed Replay Result",type:"main",index:0}],
    [{node:"Validate & Normalize",type:"main",index:0}]
  ]};
  return {trigger,loader,envelope,envelopeValid,invalidReplay,invalidReplayContext,alreadyProcessed,alreadyProcessedResult,trustedReplay,replayOrIngress,replayPipeline,renewLease,confirmRenewal,respond,invalidResponse,processedGate,deferredGate,stopMarker,stopNotProceedable};
}

function validateGraph(workflow) {
  const names = new Set();
  const ids = new Set();
  for (const node of workflow.nodes) {
    if (!node.name || names.has(node.name)) throw new Error("Duplicate or missing candidate node name: " + node.name);
    if (!node.id || ids.has(node.id)) throw new Error("Duplicate or missing candidate node ID: " + node.id);
    names.add(node.name);
    ids.add(node.id);
  }
  for (const [source, outputs] of Object.entries(workflow.connections || {})) {
    if (!names.has(source)) throw new Error("Connection source node missing: " + source);
    for (const output of outputs.main || []) {
      for (const edge of output || []) {
        if (!names.has(edge.node)) throw new Error("Connection target node missing: " + edge.node);
      }
    }
  }
  if (!workflow.nodes.some((node) => node.name === "Shopify Replay Entry Trigger")) throw new Error("Replay trigger missing");
  if (!workflow.nodes.some((node) => node.name === "Respond to Shopify")) throw new Error("Explicit webhook response node missing");
  return { node_count: workflow.nodes.length, unique_node_ids: ids.size, unique_node_names: names.size };
}

function buildCandidate(input, map, activeVersionId) {
  if (!input || input.id !== REQUIRED_WORKFLOW_ID) throw new Error("Wrong HENVALT_INGEST workflow ID");
  if (activeVersionId !== REQUIRED_ACTIVE_VERSION) throw new Error("Active workflow version drift; re-audit before building");
  const workflow = structuredClone(input);
  const changed = addFencing(workflow,map);
  addReplayAndIngressNodes(workflow);
  // Credential references are deliberately removed from the candidate export.
  // Rebind the existing Supabase service-role credential in an isolated n8n draft.
  for (const node of workflow.nodes) { delete node.credentials; node.parameters = JSON.parse(JSON.stringify(node.parameters || {}).replace(/https:\/\/ocyplckdojdubyrsxcxa\.supabase\.co/gi, "https://supabase-staging.invalid")); if (node.name === "Event Webhook") { node.parameters.path = "henvalt/ingest-candidate-no-send"; delete node.webhookId; } }
  workflow.id = "00000000-0000-4000-8000-999999999999";
  delete workflow.versionId; delete workflow.activeVersionId; delete workflow.activeVersion;
  delete workflow.createdAt; delete workflow.updatedAt; delete workflow.nodeCount; delete workflow.triggerCount;
  delete workflow.scopes; delete workflow.canExecute; delete workflow.parentFolderId; delete workflow.isArchived;
  workflow.name = "HENVALT_INGEST_CANDIDATE_NO_SEND";
  workflow.active = false;
  workflow.settings = { ...(workflow.settings || {}), availableInMCP: false };
  workflow.meta = { ...(workflow.meta || {}), henvalt_candidate: true, source_workflow_id: REQUIRED_WORKFLOW_ID, source_active_version: REQUIRED_ACTIVE_VERSION, credential_rebinding_required: true, provider_sending_enabled: false };
  workflow.tags = [];
  const graphAudit = validateGraph(workflow);
  return { workflow, graphAudit, audit: { fenced_mutation_nodes: changed, source_workflow_id: REQUIRED_WORKFLOW_ID, source_active_version: REQUIRED_ACTIVE_VERSION, expected_workflow_count: REQUIRED_WORKFLOWS, active_workflow_modified: false, credential_rebinding_required: true } };
}

if (process.argv[1] && import.meta.url.endsWith(process.argv[1].split("/").pop())) {
  const [inputPath, outputPath, activeVersionId = REQUIRED_ACTIVE_VERSION] = process.argv.slice(2);
  if (!inputPath || !outputPath) throw new Error("Usage: node n8n/shopify-ingest-candidate-builder.mjs <workflow-export.json> <candidate.json> [activeVersionId]");
  const input = JSON.parse(readFileSync(inputPath,"utf8"));
  const map = JSON.parse(readFileSync(MAP_PATH,"utf8"));
  const result = buildCandidate(input,map,activeVersionId);
  writeFileSync(outputPath,JSON.stringify(result.workflow,null,2)+"\n");
  process.stdout.write(JSON.stringify({ ...result.audit, ...result.graphAudit })+"\n");
}
export { buildCandidate };

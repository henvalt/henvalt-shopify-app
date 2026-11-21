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
function id(n) {
  return "henvalt-candidate-" + n;
}
function fencedBody(source, nodeName) {
  const original = expressionBody(source);
  const forceConstantError = nodeName === "Mark Webhook Failed" || nodeName === "Defer Payment Reconciliation";
  return "={{ (() => { const p = (" + original + "); const r = $('Validate & Normalize').item.json.replay_context; if (!r) return p; return { p_job_id: r.job_id, p_worker_id: r.worker_id, p_lease_id: r.lease_id, ...p" +
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

// The replay path enters only after the lease-fenced loader and tenant equality guard.
if (replay) {
  if (norm.__replay_tenant_mismatch || norm.ingest?.tenant_id !== replay.tenant_id) {
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
if (Number(row.http_status) !== 200 || !row.webhook_id) {
  const status = [401,404,422,503].includes(Number(row.http_status)) ? Number(row.http_status) : 503;
  return { __proceed: false, __replay: false, __http: status, __body: { status: row.result_status || "temporarily_unavailable", correlation_id: row.correlation_id || corr } };
}
const state = String(row.processing_status || "").toUpperCase();
if (row.result_status === "duplicate" && state === "PROCESSED") {
  return { __proceed: false, __replay: false, __http: 200, __body: { status: "duplicate", webhook_id: row.webhook_id, correlation_id: row.correlation_id || corr } };
}
if (["accepted","replay_accepted"].includes(row.result_status) &&
    row.replay_job_id && ["QUEUED","CLAIMED","RUNNING","RETRY_WAIT"].includes(String(row.replay_job_status || "").toUpperCase())) {
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
  const hmac = nodeByName(workflow, "HMAC Verified?");
  const valid = nodeByName(workflow, "Is Valid");
  const ingest = nodeByName(workflow, "Supabase Ingest RPC");
  const classifier = nodeByName(workflow, "Classify Result");
  const processed = nodeByName(workflow, "Mark Webhook Processed");
  const defer = nodeByName(workflow, "Defer Payment Reconciliation");

  event.parameters.responseMode = "responseNode";
  preserveReplayContext(normalizer);
  addTenantReplayGuard(bind);
  replaceClassifier(classifier);

  // Atomic public ingress: verify + resolve again inside one database transaction,
  // then persist the webhook and replay job before responding to Shopify.
  ingest.parameters.url = "https://ocyplckdojdubyrsxcxa.supabase.co/rest/v1/rpc/receive_shopify_webhook_v1";
  ingest.parameters.jsonBody = "={{ { p_shop_domain: $json.verification.shop_domain, p_topic: $json.ingest.topic, p_delivery_id: $json.ingest.source_event_id, p_hmac: $json.verification.hmac_sha256, p_raw_body_base64: $json.verification.raw_body_base64, p_payload: $json.ingest.payload, p_metadata: $json.ingest.metadata } }}";

  // Only the internal replay trigger can reach this path. It never accepts a body
  // or tenant ID from the public webhook request.
  const trigger = createNode("Shopify Replay Entry Trigger","n8n-nodes-base.executeWorkflowTrigger",{inputSource:"passthrough"},[-1100,900],1.1);
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
if (response.error || !row || typeof row !== "object") errors.push("LOAD_FAILED");
if (!uuid(claim.job_id) || claim.job_id !== row?.job_id) errors.push("JOB_ID_MISMATCH");
if (typeof claim.worker_id !== "string" || !claim.worker_id.trim()) errors.push("WORKER_MISSING");
if (!uuid(claim.lease_id) || !uuid(row?.webhook_id) || !uuid(row?.tenant_id)) errors.push("IDENTITY_INVALID");
if (!row?.payload || typeof row.payload !== "object" || Array.isArray(row.payload)) errors.push("PAYLOAD_INVALID");
if (row?.metadata?.ingress_hmac_verified !== true) errors.push("INGRESS_NOT_AUTHENTICATED");
const shop = String(row?.metadata?.shop_domain || "").toLowerCase();
if (!/^[a-z0-9][a-z0-9-]*\\.myshopify\\.com$/.test(shop)) errors.push("SHOP_INVALID");
if (row?.metadata?.shopify_webhook_id !== row?.source_event_id || !row?.source_event_id) errors.push("DELIVERY_ID_INVALID");
if (!row?.lease_expires_at || Date.parse(row.lease_expires_at) <= Date.now()) errors.push("LEASE_EXPIRED");
if (row?.webhook_processed === true) errors.push("ALREADY_PROCESSED");
if (errors.length) return { __replay_invalid: true, __replay_reason: errors.join(",") };
const body = { ...row.payload, event_id: row.source_event_id };
const headers = {
  "x-shopify-shop-domain": shop,
  "x-shopify-topic": row.topic,
  "x-shopify-webhook-id": row.source_event_id
};
return {
  body, headers, query: {},
  replay_context: {
    job_id: claim.job_id, worker_id: claim.worker_id.trim(), lease_id: claim.lease_id,
    lease_expires_at: row.lease_expires_at, tenant_id: row.tenant_id,
    webhook_id: row.webhook_id, correlation_id: row.correlation_id || null,
    source_event_id: row.source_event_id, ingress_hmac_verified: true
  }
};`
  },[-660,900],2);
  const envelopeValid = createNode("Replay Envelope Valid?","n8n-nodes-base.if",{
    conditions:{options:{caseSensitive:true,leftValue:"",typeValidation:"strict",version:2},combinator:"and",conditions:[{id:"replay-envelope-valid",leftValue:"={{ $json.replay_context !== undefined && !$json.__replay_invalid }}",rightValue:true,operator:{type:"boolean",operation:"true",singleValue:true}}]},options:{}
  },[-440,900],2.2);
  const invalidReplay = createNode("Stop Invalid Replay Envelope","n8n-nodes-base.stopAndError",{errorMessage:"=Shopify replay envelope rejected: {{ $json.__replay_reason || 'invalid lease-bound stored event' }}"},[-220,1120],1);
  const trustedReplay = createNode("Is Trusted Replay?","n8n-nodes-base.if",{
    conditions:{options:{caseSensitive:true,leftValue:"",typeValidation:"strict",version:2},combinator:"and",conditions:[{id:"trusted-replay",leftValue:"={{ !!$('Validate & Normalize').item.json.replay_context }}",rightValue:true,operator:{type:"boolean",operation:"true",singleValue:true}}]},options:{}
  },[180,600],2.2);
  const replayOrIngress = createNode("Is Replay Entry?","n8n-nodes-base.if",{
    conditions:{options:{caseSensitive:true,leftValue:"",typeValidation:"strict",version:2},combinator:"and",conditions:[{id:"is-replay-entry",leftValue:"={{ !!$('Validate & Normalize').item.json.replay_context }}",rightValue:true,operator:{type:"boolean",operation:"true",singleValue:true}}]},options:{}
  },[1120,600],2.2);
  const replayPipeline = createNode("Replay Pipeline?","n8n-nodes-base.if",{
    conditions:{options:{caseSensitive:true,leftValue:"",typeValidation:"strict",version:2},combinator:"and",conditions:[{id:"replay-pipeline",leftValue:"={{ $json.__replay === true }}",rightValue:true,operator:{type:"boolean",operation:"true",singleValue:true}}]},options:{}
  },[448,0],2.2);
  const respond = createNode("Respond to Shopify","n8n-nodes-base.respondToWebhook",{
    respondWith:"json",responseBody:"={{ $json.__body || { status: 'temporarily_unavailable' } }}",
    options:{responseCode:"={{ $json.__http || 503 }}"}
  },[672,-200],1.4);
  const invalidResponse = createNode("Build Invalid Ingress Response","n8n-nodes-base.set",{
    mode:"manual",assignments:{assignments:[
      {id:"invalid-http",name:"__http",type:"number",value:"={{ $json.__http || ($json.__tenant_mapping_missing ? 404 : 422) }}"},
      {id:"invalid-body",name:"__body",type:"object",value:"={{ { status: $json.__tenant_lookup_error ? 'temporarily_unavailable' : 'malformed_event', correlation_id: $json.correlation_id } }}"}
    ]},includeOtherFields:true,options:{}
  },[448,320],3.4);
  const hmacResponse = createNode("Build HMAC Rejection Response","n8n-nodes-base.set",{
    mode:"manual",assignments:{assignments:[
      {id:"hmac-http",name:"__http",type:"number",value:401},
      {id:"hmac-body",name:"__body",type:"object",value:"={{ { status: 'invalid_hmac' } }}"}
    ]},includeOtherFields:true,options:{}
  },[672,520],3.4);

  // The replay route bypasses only the second HMAC RPC. It still resolves the shop
  // and Bind Tenant Context enforces equality with the loader's tenant_id.
  workflow.connections["Engine Config"] = {main:[[{node:"Is Trusted Replay?",type:"main",index:0}]]};
  workflow.connections["Is Trusted Replay?"] = {main:[
    [{node:"Resolve Shopify Tenant",type:"main",index:0}],
    [{node:"Verify Shopify HMAC",type:"main",index:0}]
  ]};
  workflow.connections["HMAC Verified?"].main[0] = [{node:"Resolve Shopify Tenant",type:"main",index:0}];
  workflow.connections["HMAC Verified?"].main[1] = [{node:"Build HMAC Rejection Response",type:"main",index:0}];
  workflow.connections["Bind Tenant Context"].main = [[{node:"Is Valid",type:"main",index:0}]];
  workflow.connections["Is Valid"].main[0] = [{node:"Is Replay Entry?",type:"main",index:0}];
  workflow.connections["Is Valid"].main[1] = [{node:"Build Invalid Ingress Response",type:"main",index:0}];
  workflow.connections["Is Replay Entry?"] = {main:[
    [{node:"Classify Result",type:"main",index:0}],
    [{node:"Supabase Ingest RPC",type:"main",index:0}]
  ]};
  workflow.connections["Supabase Ingest RPC"].main = [[{node:"Classify Result",type:"main",index:0}],[{node:"Classify Result",type:"main",index:0}]];
  workflow.connections["Classify Result"].main = [[{node:"Replay Pipeline?",type:"main",index:0}]];
  workflow.connections["Replay Pipeline?"] = {main:[
    [{node:"Should Process?",type:"main",index:0}],
    [{node:"Respond to Shopify",type:"main",index:0}]
  ]};
  workflow.connections["Should Process?"].main[1] = [{node:"Respond to Shopify",type:"main",index:0}];
  workflow.connections["Build Invalid Ingress Response"] = {main:[[{node:"Respond to Shopify",type:"main",index:0}]]};
  workflow.connections["Build HMAC Rejection Response"] = {main:[[{node:"Respond to Shopify",type:"main",index:0}]]};
  workflow.connections["Replay Envelope Valid?"] = {main:[
    [{node:"Validate & Normalize",type:"main",index:0}],
    [{node:"Stop Invalid Replay Envelope",type:"main",index:0}]
  ]};
  workflow.connections["Shopify Replay Entry Trigger"] = {main:[[{node:"Load Shopify Replay Row",type:"main",index:0}]]};
  workflow.connections["Load Shopify Replay Row"] = {main:[[{node:"Build Shopify Replay Envelope",type:"main",index:0}]]};
  workflow.connections["Build Shopify Replay Envelope"] = {main:[[{node:"Replay Envelope Valid?",type:"main",index:0}]]};
  workflow.connections["Event Webhook"].main = [[{node:"Validate & Normalize",type:"main",index:0}]];
  // Existing ingress path and replay trigger are separate roots feeding the same normalizer.
  workflow.connections["Event Webhook"].main[0].push({node:"Validate & Normalize",type:"main",index:0});
  // n8n allows multiple incoming edges; avoid a second copy of the public root edge.
  workflow.connections["Event Webhook"].main[0] = [{node:"Validate & Normalize",type:"main",index:0}];

  addNode(workflow,trigger); addNode(workflow,loader); addNode(workflow,envelope); addNode(workflow,envelopeValid);
  addNode(workflow,invalidReplay); addNode(workflow,trustedReplay); addNode(workflow,replayOrIngress);
  addNode(workflow,replayPipeline); addNode(workflow,respond); addNode(workflow,invalidResponse); addNode(workflow,hmacResponse);

  // n8n graph connections support multiple upstream nodes. Append replay envelope
  // as an additional source for the existing normalizer.
  workflow.connections["Build Shopify Replay Envelope"] = {main:[[{node:"Replay Envelope Valid?",type:"main",index:0}]]};
  workflow.connections["Replay Envelope Valid?"] = {main:[
    [{node:"Validate & Normalize",type:"main",index:0}],
    [{node:"Stop Invalid Replay Envelope",type:"main",index:0}]
  ]};
  return {trigger,loader,envelope,envelopeValid,invalidReplay,trustedReplay,replayOrIngress,replayPipeline,respond,invalidResponse,hmacResponse};
}

function buildCandidate(input, map, activeVersionId) {
  if (!input || input.id !== REQUIRED_WORKFLOW_ID) throw new Error("Wrong HENVALT_INGEST workflow ID");
  if (activeVersionId !== REQUIRED_ACTIVE_VERSION) throw new Error("Active workflow version drift; re-audit before building");
  const workflow = structuredClone(input);
  const changed = addFencing(workflow,map);
  addReplayAndIngressNodes(workflow);
  // Credential references are deliberately removed from the candidate export.
  // Rebind the existing Supabase service-role credential in an isolated n8n draft.
  for (const node of workflow.nodes) delete node.credentials;
  workflow.name = "HENVALT_INGEST_CANDIDATE_NO_SEND";
  workflow.active = false;
  workflow.meta = { ...(workflow.meta || {}), henvalt_candidate: true, source_workflow_id: REQUIRED_WORKFLOW_ID, source_active_version: REQUIRED_ACTIVE_VERSION, credential_rebinding_required: true, provider_sending_enabled: false };
  workflow.tags = [];
  return { workflow, audit: { fenced_mutation_nodes: changed, source_workflow_id: REQUIRED_WORKFLOW_ID, source_active_version: REQUIRED_ACTIVE_VERSION, expected_workflow_count: REQUIRED_WORKFLOWS, active_workflow_modified: false, credential_rebinding_required: true } };
}

if (process.argv[1] && import.meta.url.endsWith(process.argv[1].split("/").pop())) {
  const [inputPath, outputPath, activeVersionId = REQUIRED_ACTIVE_VERSION] = process.argv.slice(2);
  if (!inputPath || !outputPath) throw new Error("Usage: node n8n/shopify-ingest-candidate-builder.mjs <workflow-export.json> <candidate.json> [activeVersionId]");
  const input = JSON.parse(readFileSync(inputPath,"utf8"));
  const map = JSON.parse(readFileSync(MAP_PATH,"utf8"));
  const result = buildCandidate(input,map,activeVersionId);
  writeFileSync(outputPath,JSON.stringify(result,null,2)+"\n");
  process.stdout.write(JSON.stringify(result.audit)+"\n");
}
export { buildCandidate };

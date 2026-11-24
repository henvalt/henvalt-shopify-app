import { readFileSync, writeFileSync } from "node:fs";

function replaceOne(source, search, replacement, label) {
  if (typeof source !== "string" || !source.includes(search)) {
    throw new Error("Missing source anchor: " + label);
  }
  return source.replace(search, replacement);
}

const CANDIDATE_ID = "00000000-0000-4000-8000-999999999997";
const NODE_IDS = [
  "10000000-0000-4000-8000-000000000001",
  "10000000-0000-4000-8000-000000000002",
  "10000000-0000-4000-8000-000000000003",
  "10000000-0000-4000-8000-000000000004",
  "10000000-0000-4000-8000-000000000005",
  "10000000-0000-4000-8000-000000000006",
  "10000000-0000-4000-8000-000000000007",
  "10000000-0000-4000-8000-000000000008",
  "10000000-0000-4000-8000-000000000009",
  "10000000-0000-4000-8000-000000000010",
  "10000000-0000-4000-8000-000000000011",
  "10000000-0000-4000-8000-000000000012",
  "10000000-0000-4000-8000-000000000013",
  "10000000-0000-4000-8000-000000000014",
  "10000000-0000-4000-8000-000000000015",
  "10000000-0000-4000-8000-000000000016",
  "10000000-0000-4000-8000-000000000017",
  "10000000-0000-4000-8000-000000000018",
  "10000000-0000-4000-8000-000000000019",
  "10000000-0000-4000-8000-000000000020",
  "10000000-0000-4000-8000-000000000021",
  "10000000-0000-4000-8000-000000000022",
  "10000000-0000-4000-8000-000000000023",
  "10000000-0000-4000-8000-000000000024",
  "10000000-0000-4000-8000-000000000025",
  "10000000-0000-4000-8000-000000000026",
  "10000000-0000-4000-8000-000000000027",
  "10000000-0000-4000-8000-000000000028"
];

function edge(node, index = 0) {
  return { node, type: "main", index };
}
function ifNode(name, id, expression, position) {
  return {
    id, name, type: "n8n-nodes-base.if", typeVersion: 2.3, position,
    parameters: {
      conditions: {
        options: { caseSensitive: true, leftValue: "", typeValidation: "strict", version: 2 },
        combinator: "and",
        conditions: [{
          id: "condition-" + id.slice(-3),
          leftValue: expression,
          rightValue: true,
          operator: { type: "boolean", operation: "true", singleValue: true }
        }]
      },
      options: {}
    }
  };
}
function postgresNode(name, id, query, queryReplacement, position, options = {}) {
  return {
    id, name, type: "n8n-nodes-base.postgres", typeVersion: 2.7, position,
    parameters: {
      operation: "executeQuery",
      query,
      options: { queryReplacement }
    },
    ...(options.alwaysOutputData ? { alwaysOutputData: true } : {}),
    ...(options.onError ? { onError: options.onError } : {})
  };
}
function buildNodes(manifest, normalizerSource) {
  const id = Object.fromEntries(NODE_IDS.map((v, i) => [i, v]));
  const claimExpr = "={{ [$('Init Worker').first().json.worker_id] }}";
  const leaseExpr = "={{ [$('Normalize Shopify Replay Claim').item.json.job_id, $('Normalize Shopify Replay Claim').item.json.worker_id, $('Normalize Shopify Replay Claim').item.json.lease_id] }}";
  const retryExpr = "={{ [$('Normalize Shopify Replay Claim').item.json.job_id, $('Normalize Shopify Replay Claim').item.json.worker_id, $('Normalize Shopify Replay Claim').item.json.lease_id, 'SHOPIFY_REPLAY_PROCESSING_FAILED', 300] }}";
  const n = [
    postgresNode("Claim Shopify Replay Job", id[0],
      "SELECT * FROM henvalt.claim_shopify_replay_job($1, 180)", claimExpr, [4600, 400],
      { alwaysOutputData: true, onError: "stopWorkflow" }),
    {
      id: id[1], name: "Normalize Shopify Replay Claim", type: "n8n-nodes-base.code", typeVersion: 2,
      position: [4820, 400],
      parameters: { mode: "runOnceForEachItem", jsCode: normalizerSource }
    },
    ifNode("Replay Job Claimed?", id[2], "={{ $json.claim_row_present === true }}", [5040, 400]),
    postgresNode("Load Shopify Replay Job", id[3],
      "SELECT * FROM henvalt.load_shopify_webhook_replay_job($1, $2, $3)", leaseExpr, [5260, 320],
      { alwaysOutputData: true, onError: "continueErrorOutput" }),
    ifNode("Replay Claim Valid?", id[4], "={{ $json.guard_valid === true }}", [5480, 400]),
    ifNode("Replay Load Valid?", id[5],
      "={{ !!$json.job_id && !!$json.webhook_id && !!$json.tenant_id && !!$json.lease_expires_at }}", [5700, 320]),
    ifNode("Replay Already Processed?", id[6], "={{ $json.webhook_processed === true }}", [5920, 320]),
    {
      id: id[7], name: "Call HENVALT_INGEST Replay Entry", type: "n8n-nodes-base.executeWorkflow", typeVersion: 1.4,
      position: [6140, 400],
      parameters: {
        ...manifest.executable_node_contracts["Call HENVALT_INGEST Replay Entry"].parameters,
        // The loader returns the webhook row but deliberately omits worker_id and lease_id.
        // Preserve the exact trusted claim tuple across the subworkflow boundary.
        workflowInputs: {
          ...manifest.executable_node_contracts["Call HENVALT_INGEST Replay Entry"].parameters.workflowInputs,
          value: {
            job_id: "={{ $('Normalize Shopify Replay Claim').item.json.job_id }}",
            worker_id: "={{ $('Normalize Shopify Replay Claim').item.json.worker_id }}",
            lease_id: "={{ $('Normalize Shopify Replay Claim').item.json.lease_id }}"
          }
        },
        workflowId: { __rl: true, mode: "id", value: "00000000-0000-4000-8000-999999999999" }
      },
      onError: "continueErrorOutput"
    },
    ifNode("Replay Ingest Processed?", id[8],
      "={{ $json.mark_webhook_processed === true || $json.deferred_payment_handoff === true }}", [6360, 400]),
    postgresNode("Complete Shopify Replay Job", id[9],
      "SELECT henvalt.complete_shopify_replay_job($1, $2, $3) AS result", leaseExpr, [6580, 240],
      { onError: "continueErrorOutput" }),
    ifNode("Replay Completion Accepted?", id[10], "={{ $json.result === true }}", [6800, 240]),
    postgresNode("Retry Shopify Replay Job", id[11],
      "SELECT henvalt.retry_shopify_replay_job($1, $2, $3, $4, $5) AS result", retryExpr, [6580, 560],
      { onError: "continueErrorOutput" }),
    ifNode("Replay Retry Accepted?", id[12], "={{ $json.result === true }}", [6800, 560]),
    { id: id[13], name: "Stop Replay Lease Lost", type: "n8n-nodes-base.noOp", typeVersion: 1, position: [7020, 760], parameters: {} },
    ifNode("Claimed Job Valid?", id[14], "={{ $json.claim_valid === true }}", [7240, 720]),
    postgresNode("Resume Delivery Retry Generation", id[15],
      "SELECT henvalt.enqueue_delivery_retry_generation_job($1,$2,$3) AS result",
      "={{ [$('Normalize & Guard').item.json.intervention_id, $('Normalize & Guard').item.json.job_id, $('Normalize & Guard').item.json.worker_id] }}",
      [7460, 720], { onError: "continueErrorOutput" }),
    ifNode("Resume Delivery Retry Decision?", id[16],
      "={{ $json.result && $json.result.action === 'CONTINUE_NORMAL' }}", [7680, 720]),
    postgresNode("Retry Delivery Retry Resume Job", id[17],
      "SELECT henvalt.retry_job($1,$2,$3,$4) AS result",
      "={{ [$('Normalize & Guard').item.json.job_id, $('Normalize & Guard').item.json.worker_id, 'DELIVERY_RETRY_GENERATION_RESUME_FAILED', 300] }}",
      [7460, 980], { onError: "continueErrorOutput" }),
    ifNode("Is Delivery Retry Generation Job?", id[18],
      "={{ $('Normalize & Guard').item.json.job_type === 'execute_delivery_retry_generation' }}", [7900, 620]),
    postgresNode("Load Delivery Retry Envelope", id[19],
      "SELECT * FROM henvalt.load_delivery_retry_envelope($1,$2,$3,$4,$5,$6)",
      "={{ [$('Normalize & Guard').item.json.job_id, $('Normalize & Guard').item.json.worker_id, $('Normalize & Guard').item.json.tenant_id, $('Normalize & Guard').item.json.intervention_id, $('Normalize & Guard').item.json.delivery_request_id, $('Normalize & Guard').item.json.generation_number] }}",
      [8120, 620], { alwaysOutputData: true, onError: "continueErrorOutput" }),
    ifNode("Delivery Retry Envelope Valid?", id[20],
      "={{ !!$json.delivery_request_id && !!$json.message_id && !!$json.html_body && !!$json.text_body }}", [8340, 620]),
    {
      id: id[21], name: "Build Delivery Retry Payload", type: "n8n-nodes-base.code", typeVersion: 2,
      position: [8560, 520],
      parameters: {
        mode: "runOnceForEachItem",
        jsCode: [
          "const e = $json || {};",
          "return { json: {",
          "  delivery_request_id: e.delivery_request_id,",
          "  message_id: e.message_id,",
          "  tenant_id: e.tenant_id,",
          "  recovery_id: e.recovery_id,",
          "  opportunity_id: e.opportunity_id,",
          "  intervention_id: e.intervention_id,",
          "  channel: e.channel,",
          "  to: e.recipient,",
          "  subject: e.subject,",
          "  html_body: e.html_body,",
          "  text_body: e.text_body,",
          "  tracking_token: e.tracking_token,",
          "  correlation_id: e.correlation_id,",
          "  idempotency_key: e.idempotency_key,",
          "  metadata: { delivery_generation_retry: true }",
          "} };"
        ].join("\n")
      }
    },
    postgresNode("Fail Delivery Retry Envelope", id[22],
      "SELECT henvalt.resolve_intervention_send_failure($1,'FAILED'::henvalt.intervention_status,'DELIVERY_RETRY_ENVELOPE_INVALID') AS resolved",
      "={{ [$('Normalize & Guard').item.json.intervention_id] }}",
      [8560, 820], { onError: "continueErrorOutput" }),
    postgresNode("Retry Delivery Retry Job", id[23],
      "SELECT henvalt.retry_job($1,$2,$3,$4) AS result",
      "={{ [$('Normalize & Guard').item.json.job_id, $('Normalize & Guard').item.json.worker_id, 'DELIVERY_RETRY_ENVELOPE_LOAD_FAILED', 300] }}",
      [8340, 1040], { onError: "continueErrorOutput" }),
    postgresNode("Create Delivery Retry Generation Job", id[24],
      "SELECT henvalt.enqueue_delivery_retry_generation_job($1,$2,$3,$4,$5) AS result",
      "={{ [$('Normalize & Guard').item.json.intervention_id, $('Normalize & Guard').item.json.job_id, $('Normalize & Guard').item.json.worker_id, $('Classify Delivery Failure').item.json.delivery_request_id, $('Classify Delivery Failure').item.json.delivery_attempt_id] }}",
      [7240, 1260], { onError: "continueErrorOutput" }),
    ifNode("Delivery Retry Enqueued?", id[25],
      "={{ $json.result && $json.result.action === 'RETRY_QUEUED' }}", [7460, 1260]),
    postgresNode("Retry Delivery Generation Enqueue Job", id[26],
      "SELECT henvalt.retry_job($1,$2,$3,$4) AS result",
      "={{ [$('Normalize & Guard').item.json.job_id, $('Normalize & Guard').item.json.worker_id, 'DELIVERY_RETRY_GENERATION_ENQUEUE_FAILED', 300] }}",
      [7240, 1500], { onError: "continueErrorOutput" }),
    { id: id[27], name: "Stop Delivery Retry Job Claim Lost", type: "n8n-nodes-base.noOp", typeVersion: 1, position: [7680, 1500], parameters: {} }
  ];
  return n;
}

export function buildRecoveryCandidate(source, manifest, normalizerSource) {
  if (!source || !Array.isArray(source.nodes) || !source.connections) throw new Error("Invalid source workflow");
  if (source.id !== manifest.target.workflow_id || source.nodes.length !== manifest.target.baseline_node_count) throw new Error("Source workflow does not match pinned recovery baseline");
  if (source.activeVersionId && source.activeVersionId !== manifest.target.inspected_active_version) throw new Error("Active recovery version mismatch");
  if (typeof normalizerSource !== "string" || !normalizerSource.includes('normalizeShopifyReplayClaim')) throw new Error("Missing inline replay claim normalizer");
  const workflow = JSON.parse(JSON.stringify(source));
  workflow.id = CANDIDATE_ID;
  workflow.name = "HENVALT_RECOVERY_CANDIDATE_NO_SEND";
  workflow.active = false;
  delete workflow.versionId;
  delete workflow.activeVersionId;
  delete workflow.createdAt;
  delete workflow.updatedAt;
  delete workflow.staticData;
  delete workflow.pinData;
  workflow.settings = { ...(workflow.settings || {}), availableInMCP: false };
  const deliveryCall = workflow.nodes.find((node) => node.name === "Call HENVALT_DELIVERY");
  if (!deliveryCall || !deliveryCall.parameters?.workflowId) throw new Error("Existing delivery subworkflow call is missing");
  deliveryCall.parameters.workflowId.value = "00000000-0000-4000-8000-999999999996";
  workflow.nodes = workflow.nodes.map((node) => {
    const clean = { ...node };
    delete clean.credentials;
    delete clean.webhookId;
    clean.parameters = JSON.parse(JSON.stringify(clean.parameters || {}).replace(/https:\/\/ocyplckdojdubyrsxcxa\.supabase\.co/gi, "https://supabase-staging.invalid"));
    if (clean.name === "Claim Due Job") clean.alwaysOutputData = true;
    if (clean.name === "Return One-Off Email Preview" && clean.parameters?.jsCode) {
      clean.parameters.jsCode = clean.parameters.jsCode
        .replace(/sender:\s*["'][^"']*["']/, "sender: null")
        .replace(/recipient:\s*["'][^"']*["']/, "recipient: null");
    }
    return clean;
  });

  const claimDue = workflow.nodes.find((node) => node.name === "Claim Due Job");
  claimDue.parameters.query = "SELECT * FROM henvalt.claim_next_job($1, ARRAY['execute_intervention','execute_delivery_retry_generation']::text[])";

  const normalizer = workflow.nodes.find((node) => node.name === "Normalize & Guard");
  let normalizerCode = normalizer.parameters.jsCode;
  normalizerCode = replaceOne(
    normalizerCode,
    'const interventionId = payload.intervention_id != null ? payload.intervention_id : null;',
    'const interventionId = payload.intervention_id != null ? payload.intervention_id : null;\n' +
    'const tenantId = j.tenant_id != null ? j.tenant_id : (payload.tenant_id != null ? payload.tenant_id : null);\n' +
    'const deliveryRequestId = payload.delivery_request_id != null ? payload.delivery_request_id : null;\n' +
    'const generationNumber = payload.generation_number != null ? Number(payload.generation_number) : null;\n' +
    'const jobType = j.job_type != null ? j.job_type : null;\n' +
    'const claimValid = jobType === "execute_intervention"\n' +
    '  ? interventionId != null\n' +
    '  : jobType === "execute_delivery_retry_generation"\n' +
    '    ? interventionId != null && tenantId != null && deliveryRequestId != null && Number.isInteger(generationNumber)\n' +
    '    : false;',
    "generation retry claim normalization"
  );
  normalizerCode = replaceOne(
    normalizerCode,
    'tenant_id: payload.tenant_id != null ? payload.tenant_id : null,',
    'tenant_id: tenantId,\n  delivery_request_id: deliveryRequestId,\n  generation_number: generationNumber,',
    "retry job tenant and generation identity"
  );
  normalizerCode = replaceOne(
    normalizerCode,
    'has_job: jobId != null && interventionId != null,',
    'has_job: jobId != null,\n  claim_valid: claimValid,',
    "claimed job validity gate"
  );
  normalizer.parameters.jsCode = normalizerCode;

  const deliveryFailure = workflow.nodes.find((node) => node.name === "Classify Delivery Failure");
  deliveryFailure.parameters.jsCode = [
    'const response = $json || {};',
    'const body = response.body && typeof response.body === "object" ? response.body : {};',
    'const state = String(body.state || "UNKNOWN").toUpperCase();',
    'const reason = String(body.failure_category || "DELIVERY_RESULT_UNAVAILABLE").toUpperCase();',
    'const validUuid = (value) => typeof value === "string" && /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(value);',
    'const deliveryRequestId = body.delivery_request_id || null;',
    'const deliveryAttemptId = body.delivery_attempt_id || null;',
    'const preProviderFailure = body.pre_provider_failure === true && state === "FAILED" && validUuid(deliveryRequestId) && validUuid(deliveryAttemptId);',
    'const retryable = preProviderFailure;',
    'const final_status = state === "REJECTED" ? "SKIPPED" : "FAILED";',
    'const ng = $("Normalize & Guard").item.json;',
    'return { json: {',
    '  intervention_id: ng.intervention_id,',
    '  tenant_id: ng.tenant_id,',
    '  job_id: ng.job_id,',
    '  worker_id: ng.worker_id,',
    '  delivery_request_id: deliveryRequestId,',
    '  delivery_attempt_id: deliveryAttemptId,',
    '  pre_provider_failure: preProviderFailure,',
    '  retryable,',
    '  final_status,',
    '  reason: preProviderFailure ? "PRE_PROVIDER_FAILURE" : reason,',
    '  delivery_state: state,',
    '  http_status: response.statusCode || null',
    '} };'
  ].join("\n");

  const added = buildNodes(manifest, normalizerSource);
  const allNames = new Set(workflow.nodes.map((node) => node.name));
  for (const node of added) {
    if (allNames.has(node.name)) throw new Error("Duplicate node name: " + node.name);
    allNames.add(node.name);
  }
  const allIds = new Set(workflow.nodes.map((node) => node.id));
  for (const node of added) {
    if (allIds.has(node.id)) throw new Error("Duplicate node id: " + node.id);
    allIds.add(node.id);
  }
  workflow.nodes.push(...added);
  const c = JSON.parse(JSON.stringify(workflow.connections));
  for (const name of ["Complete Job", "Retry Job", "Retry Preflight Job", "Retry Delivery Job", "Retry Pipeline Job"]) {
    c[name] = { main: [[edge("Claim Shopify Replay Job")]] };
  }
  c["Job Claimed?"].main[1] = [edge("Claim Shopify Replay Job")];
  c["Claim Shopify Replay Job"] = { main: [[edge("Normalize Shopify Replay Claim")]] };
  c["Normalize Shopify Replay Claim"] = { main: [[edge("Replay Job Claimed?")]] };
  c["Replay Job Claimed?"] = { main: [[edge("Replay Claim Valid?")], [edge("Loop Interventions")]] };
  c["Replay Claim Valid?"] = { main: [[edge("Load Shopify Replay Job")], [edge("Stop Replay Lease Lost")]] };
  c["Load Shopify Replay Job"] = { main: [[edge("Replay Load Valid?")], [edge("Retry Shopify Replay Job")]] };
  c["Replay Load Valid?"] = { main: [[edge("Replay Already Processed?")], [edge("Retry Shopify Replay Job")]] };
  c["Replay Already Processed?"] = { main: [[edge("Complete Shopify Replay Job")], [edge("Call HENVALT_INGEST Replay Entry")]] };
  c["Call HENVALT_INGEST Replay Entry"] = { main: [[edge("Replay Ingest Processed?")], [edge("Retry Shopify Replay Job")]] };
  c["Replay Ingest Processed?"] = { main: [[edge("Complete Shopify Replay Job")], [edge("Retry Shopify Replay Job")]] };
  c["Complete Shopify Replay Job"] = { main: [[edge("Replay Completion Accepted?")], [edge("Stop Replay Lease Lost")]] };
  c["Replay Completion Accepted?"] = { main: [[edge("Loop Interventions")], [edge("Stop Replay Lease Lost")]] };
  c["Retry Shopify Replay Job"] = { main: [[edge("Replay Retry Accepted?")], [edge("Stop Replay Lease Lost")]] };
  c["Replay Retry Accepted?"] = { main: [[edge("Loop Interventions")], [edge("Stop Replay Lease Lost")]] };
  c["Stop Replay Lease Lost"] = { main: [] };

  // Every claimed job first checks for a recoverable prior pre-provider failure.
  // The dedicated retry job branch reuses the persisted message and never
  // regenerates AI content or the delivery idempotency key.
  c["Job Claimed?"] = { main: [[edge("Claimed Job Valid?")], [edge("Claim Shopify Replay Job")]] };
  c["Claimed Job Valid?"] = { main: [[edge("Resume Delivery Retry Generation")], [edge("Complete Job")]] };
  c["Resume Delivery Retry Generation"] = { main: [[edge("Resume Delivery Retry Decision?")], [edge("Retry Delivery Retry Resume Job")]] };
  c["Resume Delivery Retry Decision?"] = { main: [[edge("Is Delivery Retry Generation Job?")], [edge("Claim Shopify Replay Job")]] };
  c["Is Delivery Retry Generation Job?"] = { main: [[edge("Load Delivery Retry Envelope")], [edge("Atomic Claim Intervention")]] };
  c["Load Delivery Retry Envelope"] = { main: [[edge("Delivery Retry Envelope Valid?")], [edge("Retry Delivery Retry Job")]] };
  c["Delivery Retry Envelope Valid?"] = { main: [[edge("Build Delivery Retry Payload")], [edge("Fail Delivery Retry Envelope")]] };
  c["Build Delivery Retry Payload"] = { main: [[edge("Call HENVALT_DELIVERY")]] };
  c["Fail Delivery Retry Envelope"] = { main: [[edge("Complete Job")], [edge("Stop Delivery Retry Job Claim Lost")]] };
  c["Retry Delivery Retry Job"] = { main: [[edge("Claim Shopify Replay Job")], [edge("Stop Delivery Retry Job Claim Lost")]] };
  c["Delivery Retryable?"] = { main: [[edge("Create Delivery Retry Generation Job")], [edge("Complete Job")]] };
  c["Create Delivery Retry Generation Job"] = { main: [[edge("Delivery Retry Enqueued?")], [edge("Retry Delivery Generation Enqueue Job")]] };
  c["Delivery Retry Enqueued?"] = { main: [[edge("Claim Shopify Replay Job")], [edge("Complete Job")]] };
  c["Retry Delivery Generation Enqueue Job"] = { main: [[edge("Claim Shopify Replay Job")], [edge("Stop Delivery Retry Job Claim Lost")]] };
  c["Retry Delivery Retry Resume Job"] = { main: [[edge("Claim Shopify Replay Job")], [edge("Stop Delivery Retry Job Claim Lost")]] };
  c["Stop Delivery Retry Job Claim Lost"] = { main: [] };
  workflow.connections = c;
  const ids = workflow.nodes.map((node) => node.id);
  const names = workflow.nodes.map((node) => node.name);
  if (new Set(ids).size !== ids.length || new Set(names).size !== names.length) throw new Error("Candidate graph has duplicate node IDs or names");
  for (const [from, outputs] of Object.entries(c)) {
    if (!names.includes(from)) throw new Error("Unknown connection source: " + from);
    for (const output of outputs.main || []) for (const target of output || []) {
      if (!names.includes(target.node)) throw new Error("Unknown connection target: " + target.node);
    }
  }
  if (workflow.active !== false || workflow.settings.availableInMCP !== false) throw new Error("Candidate safety flags invalid");
  if (workflow.nodes.some((node) => node.credentials || node.webhookId)) throw new Error("Candidate contains credentials or webhook IDs");
  if (workflow.nodes.some((node) => /MailerSend|provider send/i.test(node.name))) throw new Error("Provider-send node found in recovery candidate");
  return {
    workflow,
    audit: {
      source_workflow_id: source.id,
      source_active_version: manifest.target.inspected_active_version,
      baseline_nodes: source.nodes.length,
      candidate_nodes: workflow.nodes.length,
      unique_node_ids: new Set(ids).size,
      unique_node_names: new Set(names).size,
      credentials_removed: true,
      webhook_ids_removed: true,
      provider_send_nodes: 0,
      delivery_retry_generation_branch: true,
      claimed_job_types: ['execute_intervention','execute_delivery_retry_generation'],
      active: false,
      available_in_mcp: false
    }
  };
}

if (import.meta.url === `file://${process.argv[1]}`) {
  const fixture = JSON.parse(readFileSync("n8n/fixtures/henvalt-recovery-active-2026-11-24.sanitized.json", "utf8"));
  const manifest = JSON.parse(readFileSync("n8n/shopify-recovery-replay-graph-patch.json", "utf8"));
  const normalizer = readFileSync("n8n/shopify-replay-claim-normalizer-node-candidate.js", "utf8");
  const result = buildRecoveryCandidate(fixture.workflow, manifest, normalizer);
  writeFileSync("n8n/HENVALT_RECOVERY_CANDIDATE_NO_SEND.json", JSON.stringify(result.workflow, null, 2) + "\n");
  process.stdout.write(JSON.stringify(result.audit) + "\n");
}

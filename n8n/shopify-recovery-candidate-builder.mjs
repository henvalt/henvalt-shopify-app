import { readFileSync, writeFileSync } from "node:fs";

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
  "10000000-0000-4000-8000-000000000014"
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
      parameters: { ...manifest.executable_node_contracts["Call HENVALT_INGEST Replay Entry"].parameters, workflowId: { __rl: true, mode: "id", value: "00000000-0000-4000-8000-999999999999" } },
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
    { id: id[13], name: "Stop Replay Lease Lost", type: "n8n-nodes-base.noOp", typeVersion: 1, position: [7020, 760], parameters: {} }
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
  workflow.nodes = workflow.nodes.map((node) => {
    const clean = { ...node };
    delete clean.credentials;
    delete clean.webhookId;
    if (clean.name === "Claim Due Job") clean.alwaysOutputData = true;
    if (clean.name === "Return One-Off Email Preview" && clean.parameters?.jsCode) {
      clean.parameters.jsCode = clean.parameters.jsCode.replace(/recipient:\s*["'][^"']*["']/, "recipient: null");
    }
    return clean;
  });
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
      active: false,
      available_in_mcp: false
    }
  };
}

if (import.meta.url === `file://${process.argv[1]}`) {
  const fixture = JSON.parse(readFileSync("n8n/fixtures/henvalt-recovery-active-2026-11-21.sanitized.json", "utf8"));
  const manifest = JSON.parse(readFileSync("n8n/shopify-recovery-replay-graph-patch.json", "utf8"));
  const normalizer = readFileSync("n8n/shopify-replay-claim-normalizer-node-candidate.js", "utf8");
  const result = buildRecoveryCandidate(fixture.workflow, manifest, normalizer);
  writeFileSync("n8n/HENVALT_RECOVERY_CANDIDATE_NO_SEND.json", JSON.stringify(result.workflow, null, 2) + "\n");
  process.stdout.write(JSON.stringify(result.audit) + "\n");
}

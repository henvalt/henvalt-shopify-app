import { readFileSync, writeFileSync } from "node:fs";
import { buildRecoveryCandidate } from "./shopify-recovery-candidate-builder.mjs";

const BILLING_CANDIDATE_ID = "00000000-0000-4000-8000-999999999995";
const BILLING_NODE_IDS = [
  "20000000-0000-4000-8000-000000000001",
  "20000000-0000-4000-8000-000000000002"
];

const BILLING_SHOPS_QUERY = `SELECT sc.shop_domain
FROM henvalt.shopify_connections sc
JOIN henvalt.tenants t
  ON t.id = sc.tenant_id
 AND t.status = 'ACTIVE'
JOIN henvalt.billing_accounts ba
  ON ba.tenant_id = sc.tenant_id
 AND ba.status = 'ACTIVE'
 AND ba.usage_line_item_id IS NOT NULL
 AND ba.test_mode = true
JOIN LATERAL (
  SELECT bm.created_at
  FROM henvalt.billing_measurements bm
  JOIN henvalt.revenue_ledger rl
    ON rl.id = bm.ledger_entry_id
   AND rl.tenant_id = bm.tenant_id
  LEFT JOIN henvalt.billing_usage_charges buc
    ON buc.billing_measurement_id = bm.id
   AND buc.tenant_id = bm.tenant_id
  WHERE bm.tenant_id = sc.tenant_id
    AND bm.status = 'MEASURED'
    AND bm.henvalt_fee > 0
    AND bm.currency = ba.currency
    AND rl.entry_type = 'RECOVERY'
    AND rl.billable = true
    AND rl.attribution_confidence = 'CONFIRMED'
    AND rl.billing_status = 'MEASURED'
    AND (buc.id IS NULL OR buc.reconciliation_status IN ('NONE','NOT_FOUND_CONFIRMED'))
    AND (
      buc.id IS NULL
      OR (buc.status = 'FAILED' AND buc.attempt_count < 5
          AND buc.attempted_at < now() - interval '1 minute')
      OR (buc.status = 'PENDING' AND buc.attempt_count < 5
          AND buc.attempted_at < now() - interval '2 minutes')
      OR (buc.status IN ('PENDING','FAILED') AND buc.attempt_count >= 5
          AND buc.reconciliation_status = 'NONE')
    )
  ORDER BY bm.created_at, bm.id
  LIMIT 1
) due ON true
WHERE sc.active = true
  AND sc.reauth_required_at IS NULL
  AND (SELECT count(*)
         FROM henvalt.shopify_connections active_sc
        WHERE active_sc.tenant_id = sc.tenant_id
          AND active_sc.active = true) = 1
  AND (sc.access_token_expires_at IS NULL
       OR sc.access_token_expires_at > now() + interval '2 minutes')
ORDER BY due.created_at ASC, sc.shop_domain ASC
LIMIT 10`;

function edge(node) {
  return { node, type: "main", index: 0 };
}

function billingNodes() {
  return [
    {
      id: BILLING_NODE_IDS[0],
      name: "Find Shopify Usage Billing Shops",
      type: "n8n-nodes-base.postgres",
      typeVersion: 2.7,
      position: [4600, 1120],
      parameters: {
        operation: "executeQuery",
        query: BILLING_SHOPS_QUERY,
        options: {}
      },
      notes: "Selects at most ten active shops with confirmed, billable, positive recovery fees whose usage charge is new or retry-due. Refund credits are allocated by the worker's transactional claim RPC, not by this discovery query."
    },
    {
      id: BILLING_NODE_IDS[1],
      name: "Call Shopify Usage Billing Worker",
      type: "n8n-nodes-base.httpRequest",
      typeVersion: 4.2,
      position: [4840, 1120],
      parameters: {
        method: "POST",
        url: "https://supabase-staging.invalid/functions/v1/henvalt-shopify-usage-billing",
        authentication: "genericCredentialType",
        genericAuthType: "httpHeaderAuth",
        sendBody: true,
        specifyBody: "json",
        jsonBody: "={{ { shop: $json.shop_domain } }}",
        options: {
          response: {
            response: {
              fullResponse: true,
              neverError: true,
              responseFormat: "json"
            }
          },
          timeout: 30000
        }
      },
      onError: "continueRegularOutput",
      notes: "STAGING ONLY. Assign a dedicated Header Auth credential containing Authorization: Bearer <staging worker token> before any staging execution. The Supabase Edge Function must use verify_jwt=false because the handler validates this dedicated bearer token itself. Keep the .invalid URL until isolated staging exists."
    }
  ];
}

export function buildRecoveryBillingCandidate(source, manifest, normalizerSource) {
  if (manifest?.target?.keep_total_workflows !== 3) {
    throw new Error("Billing candidate must preserve the three-workflow architecture");
  }

  const base = buildRecoveryCandidate(source, manifest, normalizerSource);
  const workflow = JSON.parse(JSON.stringify(base.workflow));
  workflow.id = BILLING_CANDIDATE_ID;
  workflow.name = "HENVALT_RECOVERY_CANDIDATE_BILLING_STAGING_ONLY";

  const everyMinute = workflow.connections["Every Minute"];
  if (!everyMinute?.main?.[0]) {
    throw new Error("Pinned recovery scheduler trigger is missing");
  }
  if (everyMinute.main[0].some((connection) => connection.node === "Find Shopify Usage Billing Shops")) {
    throw new Error("Billing scheduler branch already exists");
  }

  const additions = billingNodes();
  const existingNames = new Set(workflow.nodes.map((node) => node.name));
  const existingIds = new Set(workflow.nodes.map((node) => node.id));
  for (const node of additions) {
    if (existingNames.has(node.name)) throw new Error("Duplicate node name: " + node.name);
    if (existingIds.has(node.id)) throw new Error("Duplicate node id: " + node.id);
    existingNames.add(node.name);
    existingIds.add(node.id);
    if (node.credentials || node.webhookId) {
      throw new Error("Billing candidate must not embed credentials or webhook IDs");
    }
  }

  workflow.nodes.push(...additions);
  everyMinute.main[0].push(edge("Find Shopify Usage Billing Shops"));
  workflow.connections["Find Shopify Usage Billing Shops"] = {
    main: [[edge("Call Shopify Usage Billing Worker")]]
  };
  workflow.connections["Call Shopify Usage Billing Worker"] = { main: [[]] };

  const allNames = new Set(workflow.nodes.map((node) => node.name));
  const allIds = new Set(workflow.nodes.map((node) => node.id));
  if (allNames.size !== workflow.nodes.length || allIds.size !== workflow.nodes.length) {
    throw new Error("Billing candidate contains duplicate node identities");
  }
  for (const [from, outputs] of Object.entries(workflow.connections)) {
    if (!allNames.has(from)) throw new Error("Unknown connection source: " + from);
    for (const output of outputs.main || []) {
      for (const connection of output || []) {
        if (!allNames.has(connection.node)) throw new Error("Unknown connection target: " + connection.node);
      }
    }
  }

  workflow.nodeCount = workflow.nodes.length;
  const serialized = JSON.stringify(workflow);
  if (workflow.active !== false || workflow.settings?.availableInMCP !== false) {
    throw new Error("Billing candidate must remain inactive and unavailable in MCP");
  }
  if (!serialized.includes("https://supabase-staging.invalid/functions/v1/henvalt-shopify-usage-billing")) {
    throw new Error("Billing worker endpoint must remain isolated to staging");
  }
  if (serialized.includes("ocyplckdojdubyrsxcxa.supabase.co")) {
    throw new Error("Production Supabase endpoint found in billing candidate");
  }

  return {
    workflow,
    audit: {
      source_workflow_id: source.id,
      source_active_version: manifest.target.inspected_active_version,
      baseline_nodes: source.nodes.length,
      replay_candidate_nodes: base.workflow.nodes.length,
      candidate_nodes: workflow.nodes.length,
      billing_nodes_added: additions.length,
      scheduler_branch: "Every Minute -> Find Shopify Usage Billing Shops -> Call Shopify Usage Billing Worker",
      maximum_shops_per_tick: 10,
      credentials_removed: true,
      worker_endpoint_is_staging_placeholder: true,
      active: false,
      available_in_mcp: false,
      workflow_count: manifest.target.keep_total_workflows
    }
  };
}

if (import.meta.url === `file://${process.argv[1]}`) {
  const fixture = JSON.parse(readFileSync("n8n/fixtures/henvalt-recovery-active-2026-11-24.sanitized.json", "utf8"));
  const manifest = JSON.parse(readFileSync("n8n/shopify-recovery-replay-graph-patch.json", "utf8"));
  const normalizer = readFileSync("n8n/shopify-replay-claim-normalizer-node-candidate.js", "utf8");
  if (fixture.source?.active_version_id !== manifest.target.inspected_active_version) throw new Error("Recovery fixture version drift; refresh the read-only snapshot");
  if (fixture.workflow?.activeVersionId !== manifest.target.inspected_active_version) throw new Error("Recovery workflow version drift; re-audit before building");
  const result = buildRecoveryBillingCandidate(fixture.workflow, manifest, normalizer);
  writeFileSync(
    "n8n/HENVALT_RECOVERY_CANDIDATE_BILLING_STAGING_ONLY.json",
    JSON.stringify(result.workflow, null, 2) + "\n"
  );
  process.stdout.write(JSON.stringify(result.audit) + "\n");
}

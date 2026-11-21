import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const manifest = JSON.parse(readFileSync(
  "n8n/shopify-recovery-replay-graph-patch.json",
  "utf8",
));
const active = JSON.parse(readFileSync(
  "tests/fixtures/n8n-recovery-route-snapshot.json",
  "utf8",
));
const branch = JSON.parse(readFileSync(
  "n8n/shopify-recovery-replay-branch-contract.json",
  "utf8",
));

test("candidate graph patch is pinned to the inspected live recovery version", () => {
  assert.equal(manifest.target.workflow_id, active.workflowId);
  assert.equal(manifest.target.inspected_active_version, active.activeVersionId);
  assert.equal(manifest.target.name, "HENVALT_RECOVERY");
  assert.equal(manifest.target.keep_total_workflows, 3);
  assert.equal(manifest.target.baseline_node_count, 46);
  assert.equal(manifest.status, "candidate-only; graph patch manifest, not an n8n export");
});

test("manifest explicitly preserves the production and three-workflow boundary", () => {
  assert.equal(manifest.safety.active_workflows_modified, false);
  assert.equal(manifest.safety.workflow_published, false);
  assert.equal(manifest.safety.workflow_executed, false);
  assert.equal(manifest.safety.production_database_changed, false);
  assert.equal(manifest.safety.provider_sending_enabled, false);
  assert.equal(manifest.safety.delivery_workflow_changed, false);
  assert.equal(manifest.safety.create_fourth_workflow, false);
  assert.equal(manifest.safety.no_credentials_or_customer_payload_in_manifest, true);
});

test("intervention no-job and every terminal outcome enter the replay claim", () => {
  const terminals = branch.recovery_workflow.intervention_terminal_nodes;
  assert.deepEqual(terminals, [
    "Complete Job",
    "Retry Job",
    "Retry Preflight Job",
    "Retry Delivery Job",
    "Retry Pipeline Job",
  ]);
  const added = manifest.connections_to_add;
  for (const name of terminals) {
    assert.ok(
      added.some((edge) => edge.from === name && edge.to === "Claim Shopify Replay Job"),
      name + " must route to replay claim",
    );
  }
  assert.ok(added.some((edge) =>
    edge.from === "Job Claimed?" && edge.output === 1 &&
    edge.to === "Claim Shopify Replay Job"
  ));
  assert.deepEqual(manifest.existing_connections_to_replace.map((edge) => edge.from), [
    "Complete Job",
    "Retry Job",
  ]);
});

test("empty intervention and replay queues continue the scheduler loop safely", () => {
  const claimDue = manifest.existing_node_settings.find((x) => x.node === "Claim Due Job");
  assert.equal(claimDue.settings.alwaysOutputData, true);
  const replayClaim = manifest.nodes_to_add.find((x) => x.name === "Claim Shopify Replay Job");
  assert.equal(replayClaim.settings.alwaysOutputData, true);
  assert.equal(
    manifest.required_connections.find((x) => x[0] === "Replay Job Claimed?#false")[1],
    "Loop Interventions",
  );
  assert.ok(manifest.invariants.includes("An empty intervention claim still routes to replay claim."));
  assert.ok(manifest.invariants.includes("An empty replay claim routes to Loop Interventions."));
});

test("replay claim, load, complete and retry use dedicated lease-fenced RPCs", () => {
  const nodes = new Map(manifest.nodes_to_add.map((x) => [x.name, x]));
  assert.match(nodes.get("Claim Shopify Replay Job").sql, /claim_shopify_replay_job\(\$1, 180\)/);
  assert.match(nodes.get("Load Shopify Replay Job").sql, /load_shopify_webhook_replay_job\(\$1, \$2, \$3\)/);
  assert.match(nodes.get("Complete Shopify Replay Job").sql, /complete_shopify_replay_job\(\$1, \$2, \$3\)/);
  assert.match(nodes.get("Retry Shopify Replay Job").sql, /retry_shopify_replay_job\(\$1, \$2, \$3, \$4, \$5\)/);
  for (const name of [
    "Load Shopify Replay Job",
    "Complete Shopify Replay Job",
  ]) {
    assert.deepEqual(nodes.get(name).parameters, ["job_id", "worker_id", "lease_id"]);
  }
  assert.deepEqual(
    nodes.get("Retry Shopify Replay Job").parameters.slice(0, 3),
    ["job_id", "worker_id", "lease_id"],
  );
  assert.deepEqual(
    nodes.get("Retry Shopify Replay Job").parameters.slice(3),
    ["SHOPIFY_REPLAY_PROCESSING_FAILED", 300],
  );
  assert.equal(nodes.get("Retry Shopify Replay Job").retry_delay_seconds_default, 300);
  assert.equal(nodes.get("Retry Shopify Replay Job").retry_delay_seconds_max, 3600);
});

test("only the trusted three-field lease tuple crosses into the ingest replay entry", () => {
  const node = manifest.nodes_to_add.find((x) => x.name === "Call HENVALT_INGEST Replay Entry");
  assert.deepEqual(node.input_allowlist, ["job_id", "worker_id", "lease_id"]);
  assert.equal(node.wait_for_completion, true);
  assert.equal(node.expected_result, "mark_webhook_processed === true OR deferred_payment_handoff === true");
  const processedGate = manifest.nodes_to_add.find((x) => x.name === "Replay Ingest Processed?");
  assert.match(processedGate.condition, /deferred_payment_handoff === true/);
  assert.equal(manifest.dependencies_before_staging.some((x) =>
    x.includes("dedicated Execute Workflow Trigger")
  ), true);
});

test("all replay error exits fail closed and no delivery provider node is introduced", () => {
  assert.ok(manifest.required_connections.some((x) =>
    x[0] === "Load Shopify Replay Job#error" && x[1] === "Retry Shopify Replay Job"
  ));
  assert.ok(manifest.required_connections.some((x) =>
    x[0] === "Complete Shopify Replay Job#error" && x[1] === "Stop Replay Lease Lost"
  ));
  assert.ok(manifest.required_connections.some((x) =>
    x[0] === "Retry Shopify Replay Job#error" && x[1] === "Stop Replay Lease Lost"
  ));
  assert.equal(manifest.nodes_to_add.some((x) =>
    /MailerSend|HENVALT_DELIVERY|provider/i.test(x.name)
  ), false);
  assert.ok(manifest.invariants.includes(
    "A false completion/retry result is terminal lease-lost; do not attempt a generic fallback."
  ));
});

test("manifest matches the observed graph: only two terminals are currently looped", () => {
  assert.equal(active.schedulerGraph.loopInterventions.done, "Tick Complete");
  assert.equal(active.schedulerGraph.loopInterventions.loop, "Claim Due Job");
  assert.equal(active.schedulerGraph.jobClaimedTrue, "Atomic Claim Intervention");
  assert.equal(active.schedulerGraph.jobClaimedFalse, null);
  assert.deepEqual(active.schedulerGraph.terminalEdges, {
    "Complete Job": "Loop Interventions",
    "Retry Job": "Loop Interventions",
    "Retry Preflight Job": null,
    "Retry Delivery Job": null,
    "Retry Pipeline Job": null,
  });
  assert.deepEqual(
    manifest.connections_to_add
      .filter((edge) => branch.recovery_workflow.intervention_terminal_nodes.includes(edge.from))
      .map((edge) => edge.from).sort(),
    branch.recovery_workflow.intervention_terminal_nodes.slice().sort(),
  );
});

test("empty or incomplete replay payload loads retry rather than invoking ingest", () => {
  const nodes = new Map(manifest.nodes_to_add.map((x) => [x.name, x]));
  assert.equal(nodes.get("Load Shopify Replay Job").settings.alwaysOutputData, true);
  assert.equal(
    nodes.get("Replay Load Valid?").condition,
    "={{ !!$json.job_id && !!$json.webhook_id && !!$json.tenant_id && !!$json.lease_expires_at }}",
  );
  assert.ok(manifest.required_connections.some((x) =>
    x[0] === "Replay Load Valid?#false" && x[1] === "Retry Shopify Replay Job"
  ));
  assert.ok(manifest.required_connections.some((x) =>
    x[0] === "Replay Load Valid?#true" && x[1] === "Replay Already Processed?"
  ));
});

test("empty claim loops while a present malformed claim stops fail-closed", () => {
  const nodes = new Map(manifest.nodes_to_add.map((x) => [x.name, x]));
  assert.equal(
    nodes.get("Normalize Shopify Replay Claim").code_ref,
    "n8n/shopify-replay-claim-normalizer-candidate.mjs",
  );
  assert.equal(nodes.get("Replay Job Claimed?").condition, "={{ $json.claim_row_present === true }}");
  assert.equal(nodes.get("Replay Claim Valid?").condition, "={{ $json.guard_valid === true }}");
  assert.ok(manifest.required_connections.some((x) =>
    x[0] === "Replay Job Claimed?#false" && x[1] === "Loop Interventions"
  ));
  assert.ok(manifest.required_connections.some((x) =>
    x[0] === "Replay Claim Valid?#false" && x[1] === "Stop Replay Lease Lost"
  ));
});

test("replay retries persist only a constant non-PII failure code", () => {
  const retry = manifest.nodes_to_add.find((x) => x.name === "Retry Shopify Replay Job");
  assert.equal(retry.error_reason_policy.reason, "SHOPIFY_REPLAY_PROCESSING_FAILED");
  assert.match(retry.error_reason_policy.source, /constant/);
  assert.match(retry.error_reason_policy.source, /never copy raw error message/);
  assert.equal(retry.error_reason_policy.max_delay_seconds, 3600);
});


test("candidate node versions are pinned to installed n8n definitions", () => {
  assert.deepEqual(manifest.node_type_versions, {
    "n8n-nodes-base.postgres": 2.7,
    "n8n-nodes-base.code": 2,
    "n8n-nodes-base.if": 2.3,
    "n8n-nodes-base.executeWorkflow": 1.4,
    "n8n-nodes-base.executeWorkflowTrigger": 1.1,
    "n8n-nodes-base.noOp": 1,
  });
  assert.equal(manifest.node_type_version_evidence.versions_are_exact, true);
  assert.equal(manifest.node_type_version_evidence.credentials_rebound_only_in_isolated_draft, true);
  assert.equal(manifest.node_type_version_evidence.production_workflow_unchanged, true);
});


test("replay subworkflow node contracts expose only the exact three required inputs", () => {
  const contracts = manifest.executable_node_contracts;
  const call = contracts["Call HENVALT_INGEST Replay Entry"];
  const trigger = contracts["Dedicated Replay Execute Workflow Trigger"];
  assert.equal(call.type, "n8n-nodes-base.executeWorkflow");
  assert.equal(call.typeVersion, 1.4);
  assert.equal(call.parameters.mode, "once");
  assert.equal(call.parameters.source, "database");
  assert.equal(call.parameters.workflowId.value, "VTpfGKNtu1CSQ4Rv");
  assert.equal(call.parameters.options.waitForSubWorkflow, true);
  assert.equal(call.onError, "continueErrorOutput");
  const values = call.parameters.workflowInputs.value;
  assert.deepEqual(Object.keys(values), ["job_id", "worker_id", "lease_id"]);
  assert.deepEqual(trigger.parameters.workflowInputs.values, [
    {name:"job_id",type:"string"},
    {name:"worker_id",type:"string"},
    {name:"lease_id",type:"string"},
  ]);
  assert.equal(trigger.typeVersion, 1.1);
  assert.equal(trigger.isTrigger, true);
  assert.equal(trigger.parameters.returnOutput, "lastRunOnly");
});

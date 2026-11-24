import { readFileSync, writeFileSync } from "node:fs";

const CANDIDATE_ID = "00000000-0000-4000-8000-999999999996";
const REMOVED_ONE_OFF_NODES = [
  "One-Off Test Email Trigger",
  "Prepare One-Off Test Delivery",
  "One-Off Test Authorized?",
  "MailerSend One-Off Test Email",
  "Classify One-Off Provider Result",
  "Record One-Off Test Result",
  "One-Off Test Send Result",
  "One-Off Test Send Rejected"
];

function replaceOne(source, from, to, label) {
  if (!source.includes(from)) throw new Error("Missing expected source fragment: " + label);
  return source.replace(from, to);
}

export function buildDeliveryCandidate(source) {
  if (!source || source.id !== "CvVyybGJZSnklxiZ" || !Array.isArray(source.nodes) || source.nodes.length !== 62) {
    throw new Error("Delivery source does not match pinned 62-node active workflow");
  }
  const workflow = JSON.parse(JSON.stringify(source));
  workflow.id = CANDIDATE_ID;
  workflow.name = "HENVALT_DELIVERY_CANDIDATE_NO_SEND";
  workflow.active = false;
  delete workflow.versionId;
  delete workflow.activeVersionId;
  delete workflow.createdAt;
  delete workflow.updatedAt;
  delete workflow.staticData;
  delete workflow.pinData;
  workflow.settings = { ...(workflow.settings || {}), availableInMCP: false };
  workflow.nodes = workflow.nodes
    .filter((node) => !REMOVED_ONE_OFF_NODES.includes(node.name))
    .map((node) => {
      const clean = { ...node, parameters: JSON.parse(JSON.stringify(node.parameters || {}).replace(/https:\/\/ocyplckdojdubyrsxcxa\.supabase\.co/gi, "https://supabase-staging.invalid").replace(/https:\/\/henvalt-reply-ai\.chmuhammadrehan18\.workers\.dev/gi, "https://reply-ai-staging.invalid")) };
      delete clean.credentials;
      delete clean.webhookId;
      if (clean.type === "n8n-nodes-base.webhook" && typeof clean.parameters.path === "string") {
        clean.parameters.path = "henvalt/candidate-no-send/" + clean.parameters.path.replace(/^henvalt\//, "");
      }
      if (clean.name === "MailerSend Send") {
        clean.name = "No-Send Provider Stub";
        clean.type = "n8n-nodes-base.code";
        clean.typeVersion = 2;
        clean.parameters = {
          mode: "runOnceForEachItem",
          jsCode: [
            "return { json: {",
            "  statusCode: 503,",
            "  body: { state: 'REJECTED', failure_category: 'NO_SEND_CANDIDATE', no_send_candidate: true, provider: 'NONE' }",
            "} };"
          ].join("\n")
        };
      }
      if (clean.name === "Build Delivery Response") {
        clean.parameters.jsCode = replaceOne(
          clean.parameters.jsCode,
          '    correlation_id: c.correlation_id || null',
          '    correlation_id: c.correlation_id || null,\n' +
          '    delivery_attempt_id: (() => { try { const result = $("Record Delivery Result").item.json || {}; return result.attempt_id || null; } catch (e) { return null; } })(),\\n' +
          '    pre_provider_failure: !!(c.provider_response && c.provider_response.henvalt_delivery_stage === "pre_provider")',
          "propagate stable delivery attempt identity and trusted pre-provider stage"
        );
      }
      if (clean.name === "Classify Result") {
        let code = clean.parameters.jsCode;
        code = replaceOne(
          code,
          'else if (!send || send.statusCode === undefined || send.statusCode === null) {',
          'else if (send && send.body && send.body.henvalt_delivery_stage === "pre_provider") {\n  state = "FAILED"; errorClass = String(send.body.error || "PRE_PROVIDER_FAILURE"); provider_status_code = Number(send.statusCode); provider_response = send.body; http_status = 502;\n} else if (!send || send.statusCode === undefined || send.statusCode === null) {',
          "pre-provider failure classification"
        );
        code = replaceOne(
          code,
          'send = $("MailerSend Send").item.json',
          'send = $("No-Send Provider Stub").item.json',
          "main provider node reference"
        );
        code = replaceOne(
          code,
          'else if (!send || send.statusCode === undefined || send.statusCode === null) {',
          'else if (send && send.body && send.body.no_send_candidate === true) {\n  state = "REJECTED"; errorClass = "NO_SEND_CANDIDATE"; http_status = 503; provider_response = { no_send_candidate: true };\n} else if (!send || send.statusCode === undefined || send.statusCode === null) {',
          "no-send classifier branch"
        );
        code = replaceOne(
          code,
          'provider: authBody.provider || "mailersend",',
          'provider: send && send.body && send.body.no_send_candidate === true ? "none" : (authBody.provider || "mailersend"),',
          "provider label"
        );
        code = replaceOne(
          code,
          "should_record_result: authorized,",
          "should_record_result: authorized && !(send && send.body && send.body.no_send_candidate === true),",
          "prevent no-send result persistence"
        );
        clean.parameters.jsCode = code;
      }
      return clean;
    });
  const c = JSON.parse(JSON.stringify(workflow.connections || {}));
  delete c["One-Off Test Email Trigger"];
  delete c["Prepare One-Off Test Delivery"];
  delete c["One-Off Test Authorized?"];
  delete c["MailerSend One-Off Test Email"];
  delete c["Classify One-Off Provider Result"];
  delete c["Record One-Off Test Result"];
  delete c["One-Off Test Send Result"];
  delete c["One-Off Test Send Rejected"];
  delete c["MailerSend Send"];
  c["Build Reply-To Address"] = { main: [[{ node: "No-Send Provider Stub", type: "main", index: 0 }]] };
  c["No-Send Provider Stub"] = { main: [[{ node: "Classify Result", type: "main", index: 0 }]] };
  workflow.connections = c;
  const names = workflow.nodes.map((n) => n.name);
  const ids = workflow.nodes.map((n) => n.id);
  if (new Set(names).size !== names.length || new Set(ids).size !== ids.length) throw new Error("Duplicate delivery candidate node names or IDs");
  for (const [from, outputs] of Object.entries(c)) {
    if (!names.includes(from)) throw new Error("Unknown connection source: " + from);
    for (const output of outputs.main || []) for (const target of output || []) {
      if (!names.includes(target.node)) throw new Error("Unknown connection target: " + target.node);
    }
  }
  if (workflow.nodes.some((n) => n.credentials || n.webhookId)) throw new Error("Credential or webhook ID remains in candidate");
  if (workflow.nodes.some((n) => REMOVED_ONE_OFF_NODES.includes(n.name))) throw new Error("One-off test path remains in candidate");
  if (workflow.nodes.some((n) => n.parameters?.url && String(n.parameters.url).includes("/functions/v1/henvalt-mailersend-delivery"))) {
    throw new Error("Provider delivery Edge Function call remains in candidate");
  }
  // The named MailerSend node is not the only possible provider-egress surface.
  // Fail closed if any remaining HTTP node points outside the candidate-only hosts.
  const allowedHttpHosts = new Set(["supabase-staging.invalid", "reply-ai-staging.invalid"]);
  const providerNodeType = /\.(?:emailSend|sendEmail|smtp|sendGrid|mailgun|mailerSend|postmark|resend)$/i;
  const providerApiHost = /(?:api\.mailersend\.com|api\.sendgrid\.com|api\.resend\.com|api\.mailgun\.net|api\.postmarkapp\.com)/i;
  const inlineNetworkCall = /\bfetch\s*\(|\baxios\b|\bXMLHttpRequest\b|\bhttps?\.(?:request|get)\s*\(|\bnet\.connect\s*\(|(?:this\.)?helpers\.httpRequest\b|\$http\b|\b(?:got|superagent|undici)\s*\(/i;
  for (const node of workflow.nodes) {
    if (providerNodeType.test(node.type)) {
      throw new Error("Provider egress node type remains in candidate: " + node.type);
    }
    if (node.type === "n8n-nodes-base.code" && inlineNetworkCall.test(node.parameters?.jsCode || "")) {
      throw new Error("Inline network-capable code remains in delivery candidate: " + node.name);
    }
    if (node.type === "n8n-nodes-base.httpRequest") {
      const rawUrl = node.parameters?.url;
      if (typeof rawUrl !== "string") throw new Error("HTTP node URL must be a literal candidate endpoint: " + node.name);
      let parsed;
      try { parsed = new URL(rawUrl); } catch { throw new Error("Invalid HTTP node URL: " + node.name); }
      if (parsed.protocol !== "https:" || !allowedHttpHosts.has(parsed.hostname) || parsed.username || parsed.password) {
        throw new Error("Non-candidate HTTP egress remains in delivery candidate: " + node.name + " -> " + parsed.hostname);
      }
    }
    const serializedParameters = JSON.stringify(node.parameters || {});
    if (providerApiHost.test(serializedParameters)) {
      throw new Error("Provider API endpoint remains in candidate: " + node.name);
    }
  }
  const stub = workflow.nodes.find((n) => n.name === "No-Send Provider Stub");
  if (!stub || stub.type !== "n8n-nodes-base.code" || !stub.parameters.jsCode.includes("no_send_candidate: true")) {
    throw new Error("No-send provider stub is missing or invalid");
  }
  const classifier = workflow.nodes.find((n) => n.name === "Classify Result").parameters.jsCode;
  if (!classifier.includes("NO_SEND_CANDIDATE") || !classifier.includes("should_record_result: authorized && !")) {
    throw new Error("No-send classifier does not fail closed");
  }
  if (workflow.active !== false || workflow.settings.availableInMCP !== false) throw new Error("Candidate must remain inactive and hidden from MCP");
  if (workflow.nodes.length !== 54) throw new Error("Unexpected delivery candidate node count: " + workflow.nodes.length);
  return {
    workflow,
    audit: {
      source_workflow_id: source.id,
      baseline_nodes: source.nodes.length,
      candidate_nodes: workflow.nodes.length,
      unique_node_ids: new Set(ids).size,
      unique_node_names: new Set(names).size,
      credentials_removed: true,
      webhook_ids_removed: true,
      one_off_test_path_removed: true,
      provider_http_send_nodes: 0,
      no_send_stub_present: true,
      active: false,
      available_in_mcp: false
    }
  };
}

if (import.meta.url === `file://${process.argv[1]}`) {
  const fixture = JSON.parse(readFileSync("n8n/fixtures/henvalt-delivery-active-2026-11-21.sanitized.json", "utf8"));
  const result = buildDeliveryCandidate(fixture.workflow);
  writeFileSync("n8n/HENVALT_DELIVERY_CANDIDATE_NO_SEND.json", JSON.stringify(result.workflow, null, 2) + "\n");
  process.stdout.write(JSON.stringify(result.audit) + "\n");
}

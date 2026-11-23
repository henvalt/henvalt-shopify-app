import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { buildDeliveryCandidate } from "../n8n/shopify-delivery-candidate-builder.mjs";

const fixture = JSON.parse(readFileSync("n8n/fixtures/henvalt-delivery-active-2026-11-21.sanitized.json", "utf8"));
const candidateId = "00000000-0000-4000-8000-999999999996";

test("delivery candidate is an inactive sanitized export with no credentials or webhook IDs", () => {
  const result = buildDeliveryCandidate(fixture.workflow);
  const w = result.workflow;
  assert.equal(w.id, candidateId);
  assert.equal(w.name, "HENVALT_DELIVERY_CANDIDATE_NO_SEND");
  assert.equal(w.active, false);
  assert.equal(w.settings.availableInMCP, false);
  assert.equal(w.nodes.length, 54);
  assert.equal(result.audit.credentials_removed, true);
  assert.equal(result.audit.webhook_ids_removed, true);
  assert.ok(w.nodes.every((n) => !n.credentials && !n.webhookId));
  assert.ok(!JSON.stringify(w).match(/[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}/i));
});

test("both provider-send entry points are blocked and one-off test branch is removed", () => {
  const w = buildDeliveryCandidate(fixture.workflow).workflow;
  const names = new Set(w.nodes.map((n) => n.name));
  for (const removed of [
    "One-Off Test Email Trigger","Prepare One-Off Test Delivery","One-Off Test Authorized?",
    "MailerSend One-Off Test Email","Classify One-Off Provider Result","Record One-Off Test Result",
    "One-Off Test Send Result","One-Off Test Send Rejected"
  ]) assert.equal(names.has(removed), false, removed);
  assert.equal(names.has("MailerSend Send"), false);
  const stub = w.nodes.find((n) => n.name === "No-Send Provider Stub");
  assert.equal(stub.type, "n8n-nodes-base.code");
  assert.match(stub.parameters.jsCode, /no_send_candidate: true/);
  assert.equal(w.connections["Build Reply-To Address"].main[0][0].node, "No-Send Provider Stub");
  assert.equal(w.connections["No-Send Provider Stub"].main[0][0].node, "Classify Result");
  assert.ok(!w.nodes.some((n) => n.parameters?.url && String(n.parameters.url).includes("/functions/v1/henvalt-mailersend-delivery")));
});

test("delivery candidate rejects alternate provider egress hidden in an ordinary HTTP node", () => {
  const directProvider = structuredClone(fixture.workflow);
  directProvider.nodes.find((n) => n.name === "Authorize & Context").parameters.url = "https://api.mailersend.com/v1/email";
  assert.throws(() => buildDeliveryCandidate(directProvider), /Non-candidate HTTP egress/);

  const unknownExternal = structuredClone(fixture.workflow);
  unknownExternal.nodes.find((n) => n.name === "Authorize & Context").parameters.url = "https://example.invalid/send";
  assert.throws(() => buildDeliveryCandidate(unknownExternal), /Non-candidate HTTP egress/);

  const smtpNode = structuredClone(fixture.workflow);
  smtpNode.nodes.find((n) => n.name === "Authorize & Context").type = "n8n-nodes-base.emailSend";
  assert.throws(() => buildDeliveryCandidate(smtpNode), /Provider egress node type/);
});

test("delivery candidate rejects provider calls hidden inside code nodes", () => {
  const hiddenFetch = structuredClone(fixture.workflow);
  hiddenFetch.nodes.find((n) => n.name === "Build Delivery Response").parameters.jsCode =
    'return await fetch("https://api.mailersend.com/v1/email");';
  assert.throws(() => buildDeliveryCandidate(hiddenFetch), /Inline network-capable code/);

  const hiddenHelperRequest = structuredClone(fixture.workflow);
  hiddenHelperRequest.nodes.find((n) => n.name === "Build Delivery Response").parameters.jsCode =
    'return await this.helpers.httpRequest({ method: "POST", url: "https://api.mailersend.com/v1/email" });';
  assert.throws(() => buildDeliveryCandidate(hiddenHelperRequest), /Inline network-capable code/);

  const hiddenProviderHost = structuredClone(fixture.workflow);
  hiddenProviderHost.nodes.find((n) => n.name === "Build Delivery Response").parameters.jsCode =
    'const provider = "https://api.sendgrid.com/v3/mail/send"; return { provider };';
  assert.throws(() => buildDeliveryCandidate(hiddenProviderHost), /Provider API endpoint/);
});

test("no-send response is rejected and is never persisted as a provider result", () => {
  const w = buildDeliveryCandidate(fixture.workflow).workflow;
  const classifier = w.nodes.find((n) => n.name === "Classify Result").parameters.jsCode;
  assert.match(classifier, /send = \$\("No-Send Provider Stub"\)\.item\.json/);
  assert.match(classifier, /NO_SEND_CANDIDATE/);
  assert.match(classifier, /should_record_result: authorized && !\(send && send\.body && send\.body\.no_send_candidate === true\)/);
  assert.equal(w.connections["Should Record Provider Result?"].main[1][0].node, "Build Delivery Response");
});

test("pre-provider Edge Function failures are classified as definitive non-egress outcomes", () => {
  const w = buildDeliveryCandidate(fixture.workflow).workflow;
  const nodes = new Map(w.nodes.map((n) => [n.name, n]));
  const context = {
    "Validate & Normalize": { item: { json: {
      precheck_ok: true, tenant_id: "tenant", delivery_request_id: "request",
      intervention_id: "intervention", recovery_id: "recovery", opportunity_id: "opportunity",
      correlation_id: "correlation"
    }}},
    "Authorize & Context": { item: { json: { statusCode: 200, body: {
      can_send: true, delivery_request_id: "request", provider: "MailerSend"
    }}}},
    "No-Send Provider Stub": { item: { json: {
      statusCode: 409,
      body: { error: "tenant_provider_credential_unavailable", henvalt_delivery_stage: "pre_provider" }
    }}}
  };
  const classifier = new Function("$", "$json", nodes.get("Classify Result").parameters.jsCode)(
    (name) => context[name],
    {}
  );
  assert.equal(classifier.state, "FAILED");
  assert.equal(classifier.error_class, "tenant_provider_credential_unavailable");
  assert.equal(classifier.provider_status_code, 409);
  assert.equal(classifier.provider_response.henvalt_delivery_stage, "pre_provider");
  assert.equal(classifier.should_record_result, true);
  assert.equal(classifier.retryable, false);
});

test("candidate webhooks use isolated path prefixes and graph connections resolve", () => {
  const w = buildDeliveryCandidate(fixture.workflow).workflow;
  const names = new Set(w.nodes.map((n) => n.name));
  const webhookPaths = w.nodes.filter((n) => n.type === "n8n-nodes-base.webhook").map((n) => n.parameters.path);
  assert.ok(webhookPaths.length > 0);
  assert.ok(webhookPaths.every((path) => path.startsWith("henvalt/candidate-no-send/")));
  for (const [source, outputs] of Object.entries(w.connections)) {
    assert.ok(names.has(source), "unknown source " + source);
    for (const output of outputs.main || []) for (const edge of output || []) assert.ok(names.has(edge.node), "unknown target " + edge.node);
  }
});


test("executed no-send stub and delivery classifier cannot report provider acceptance", () => {
  const w = buildDeliveryCandidate(fixture.workflow).workflow;
  const nodes = new Map(w.nodes.map((n) => [n.name, n]));
  const stub = new Function("$", "$json", nodes.get("No-Send Provider Stub").parameters.jsCode)(() => ({}), {});
  assert.equal(stub.json.statusCode, 503);
  assert.equal(stub.json.body.no_send_candidate, true);
  const context = {
    "Validate & Normalize": { item: { json: {
      precheck_ok: true, tenant_id: "tenant", delivery_request_id: "request",
      intervention_id: "intervention", recovery_id: "recovery", opportunity_id: "opportunity",
      correlation_id: "correlation"
    }}},
    "Authorize & Context": { item: { json: { statusCode: 200, body: {
      can_send: true, delivery_request_id: "request", provider: "MailerSend"
    }}}},
    "No-Send Provider Stub": { item: { json: stub.json } }
  };
  const classifier = new Function("$", "$json", nodes.get("Classify Result").parameters.jsCode)(
    (name) => context[name],
    {}
  );
  assert.equal(classifier.state, "REJECTED");
  assert.equal(classifier.error_class, "NO_SEND_CANDIDATE");
  assert.equal(classifier.provider, "none");
  assert.equal(classifier.should_record_result, false);
  assert.equal(classifier.retryable, false);
  const response = new Function("$", "$json", nodes.get("Build Delivery Response").parameters.jsCode)(
    (name) => ({ item: { json: classifier } }),
    {}
  );
  assert.equal(response.json.statusCode, 503);
  assert.equal(response.json.body.state, "REJECTED");
  assert.equal(response.json.body.failure_category, "NO_SEND_CANDIDATE");
});

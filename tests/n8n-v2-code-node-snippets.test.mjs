import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const source = readFileSync(new URL("../n8n/v2-n8n-code-node-snippets.md", import.meta.url), "utf8");

function codeAfter(heading, from = 0, occurrence = 0) {
  let position = from;
  for (let i = 0; i <= occurrence; i++) {
    position = source.indexOf(heading, position);
    if (position < 0) throw new Error(`missing snippet heading: ${heading}`);
    if (i < occurrence) position += heading.length;
  }
  const fence = source.indexOf("```javascript\n", position);
  if (fence < 0) throw new Error(`missing JavaScript fence after: ${heading}`);
  const start = fence + "```javascript\n".length;
  const end = source.indexOf("\n```", start);
  if (end < 0) throw new Error(`unterminated JavaScript fence after: ${heading}`);
  return source.slice(start, end);
}

function run(code, { input = {}, execution = { id: "12345" }, nodes = {}, json = {} } = {}) {
  const inputApi = {
    first: () => ({ json: input }),
    item: { json: input },
    all: () => [{ json: input }],
  };
  const nodeApi = name => nodes[name] ?? {};
  return new Function("$input", "$execution", "$", "$json", code)(inputApi, execution, nodeApi, json);
}

test("Recovery worker and stage snippets emit only bounded safe context", () => {
  const init = run(codeAfter("### 1. Init V2 Worker"));
  assert.deepEqual(init, [{ json: { worker_id: "henvalt_recovery_v2:12345" } }]);

  const stage = run(codeAfter("### 2. Assert Stage Accepted"), {
    input: { statusCode: 200, body: { accepted: true, changed: 4, secret: "must-not-forward" } },
  });
  assert.deepEqual(stage, [{ json: { accepted: true } }]);
  assert.throws(() => run(codeAfter("### 2. Assert Stage Accepted"), {
    input: { statusCode: 503, body: { accepted: false } },
  }), /v2_stage_rejected/);
});

test("Recovery claim snippet enforces exact three-field database items and emits five-field handoffs", () => {
  const code = codeAfter("### 3. Validate Claim Batch");
  const workerId = "henvalt_recovery_v2:12345";
  const item = {
    lease_id: "22222222-2222-4222-8222-222222222222",
    work_id: "11111111-1111-4111-8111-111111111111",
    work_type: "CHECKOUT_INTERVENTION",
  };
  const output = run(code, {
    input: { statusCode: 200, body: { accepted: true, claimed: 1, items: [item] } },
    nodes: { "Init V2 Worker": { first: () => ({ json: { worker_id: workerId } }) } },
  });
  assert.deepEqual(output, [{
    json: {
      work_type: "CHECKOUT_INTERVENTION",
      work_id: item.work_id,
      lease_id: item.lease_id,
      worker_id: workerId,
      correlation_id: `v2:${item.work_id}`,
    },
  }]);
  assert.throws(() => run(code, {
    input: { statusCode: 200, body: { accepted: true, claimed: 1, items: [{ ...item, recipient_email: "pii@example.com" }] } },
    nodes: { "Init V2 Worker": { first: () => ({ json: { worker_id: workerId } }) } },
  }), /v2_claim_item_invalid/);
});

test("Recovery finish snippet defers mismatched work and requires exact finish acknowledgement", () => {
  const build = codeAfter("### 5. Validate Delivery Result and Build Finish RPC Body");
  const claim = {
    work_type: "CHECKOUT_INTERVENTION",
    work_id: "11111111-1111-4111-8111-111111111111",
    lease_id: "22222222-2222-4222-8222-222222222222",
    worker_id: "worker-v2-01",
  };
  const built = run(build, {
    input: { work_type: "PIXEL_OPPORTUNITY", work_id: "33333333-3333-4333-8333-333333333333", outcome: "HANDOFF_ACCEPTED" },
    nodes: { "Validate Claim Batch": { item: { json: claim } } },
  });
  assert.equal(built.json.p_outcome, "DEFERRED");
  assert.equal(built.json.p_retry_after, "3600 seconds");

  const verify = codeAfter("### 6. Verify Finish Acknowledgement");
  const acknowledged = run(verify, {
    input: { statusCode: 200, body: { finished: true, outcome: "HANDOFF_ACCEPTED" } },
    nodes: { "Validate Delivery Result and Build Finish RPC Body": { item: { json: { expected_outcome: "HANDOFF_ACCEPTED" } } } },
  });
  assert.deepEqual(acknowledged, { json: { finished: true, outcome: "HANDOFF_ACCEPTED" } });
  assert.throws(() => run(verify, {
    input: { statusCode: 200, body: { finished: true, outcome: "TERMINAL" } },
    nodes: { "Validate Delivery Result and Build Finish RPC Body": { item: { json: { expected_outcome: "HANDOFF_ACCEPTED" } } } },
  }), /v2_finish_ack_unconfirmed/);
});

test("Delivery snippets reject extra claim data and route distinct opaque request bodies", () => {
  const deliveryStart = source.indexOf("## HENVALT_DELIVERY");
  const validate = codeAfter("### 1. Validate Opaque Claim", deliveryStart);
  const claim = {
    work_type: "CHECKOUT_INTERVENTION",
    work_id: "11111111-1111-4111-8111-111111111111",
    lease_id: "22222222-2222-4222-8222-222222222222",
    worker_id: "worker-v2-01",
    correlation_id: "v2:11111111-1111-4111-8111-111111111111",
  };
  assert.deepEqual(run(validate, { input: claim }), { json: claim });
  assert.throws(() => run(validate, { input: { ...claim, email: "pii@example.com" } }), /v2_delivery_claim_invalid/);

  const requestHeading = "Checkout branch:";
  const checkout = codeAfter(requestHeading, deliveryStart);
  const pixel = codeAfter("Pixel branch:", deliveryStart);
  assert.deepEqual(run(checkout, { input: { work_id: claim.work_id } }), { json: { intervention_id: claim.work_id } });
  assert.deepEqual(run(pixel, { input: { work_id: claim.work_id } }), { json: { opportunity_id: claim.work_id } });
});

test("Delivery classification defers missing routes and accepts ambiguous provider outcomes without resubmission", () => {
  const deliveryStart = source.indexOf("## HENVALT_DELIVERY");
  const classify = codeAfter("### 3. Classify Handoff Result", deliveryStart);
  const claim = {
    work_type: "PIXEL_OPPORTUNITY",
    work_id: "33333333-3333-4333-8333-333333333333",
    lease_id: "44444444-4444-4444-8444-444444444444",
    worker_id: "worker-v2-01",
    correlation_id: "v2:33333333-3333-4333-8333-333333333333",
  };
  const node = { "Validate Opaque Claim": { item: { json: claim } } };
  const ambiguous = run(classify, {
    input: { statusCode: 202, body: { accepted: true, status: "ambiguous_provider_submission" } },
    nodes: node,
  });
  assert.equal(ambiguous.json.outcome, "HANDOFF_ACCEPTED");
  assert.equal(ambiguous.json.reason, "accepted_provider_reconciliation_pending");

  const missingRoute = run(classify, { input: { statusCode: 404, body: { message: "not found" } }, nodes: node });
  assert.equal(missingRoute.json.outcome, "DEFERRED");
  assert.equal(missingRoute.json.retry_after_seconds, 3600);

  const rejection = run(classify, {
    input: { statusCode: 502, body: { accepted: false, error: "provider_submission_rejected" } },
    nodes: node,
  });
  assert.equal(rejection.json.outcome, "TERMINAL");
});

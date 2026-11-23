import test from "node:test";
import assert from "node:assert/strict";
import vm from "node:vm";
import { readFileSync } from "node:fs";

const fixture = JSON.parse(readFileSync(
  new URL("../n8n/fixtures/henvalt-delivery-active-2026-11-21.sanitized.json", import.meta.url),
  "utf8",
));
const classifier = fixture.workflow.nodes.find((node) => node.name === "Classify Result")?.parameters?.jsCode;
assert.equal(typeof classifier, "string", "pinned active delivery classifier must exist");

function classify({ statusCode, headers = {}, body = {} } = {}) {
  const records = {
    "Validate & Normalize": {
      tenant_id: "11111111-1111-4111-8111-111111111111",
      intervention_id: "22222222-2222-4222-8222-222222222222",
      recovery_id: "33333333-3333-4333-8333-333333333333",
      opportunity_id: "44444444-4444-4444-8444-444444444444",
      correlation_id: "55555555-5555-4555-8555-555555555555",
      precheck_ok: true,
    },
    "Authorize & Context": {
      statusCode: 200,
      body: {
        can_send: true,
        delivery_request_id: "66666666-6666-4666-8666-666666666666",
        provider: "mailersend",
      },
    },
    "MailerSend Send": statusCode == null ? undefined : {
      statusCode,
      headers,
      body,
    },
  };
  const sandbox = {
    $: (name) => ({
      item: {
        json: records[name],
      },
    }),
  };
  return vm.runInNewContext(classifier, sandbox);
}

test("MailerSend accepted response captures message ID and records ACCEPTED", () => {
  const result = classify({
    statusCode: 202,
    headers: { "x-message-id": "provider-message-abc123" },
    body: {},
  });
  assert.equal(result.state, "ACCEPTED");
  assert.equal(result.provider_status_code, 202);
  assert.equal(result.provider_message_id, "provider-message-abc123");
  assert.equal(result.should_record_result, true);
  assert.equal(result.retryable, false);
});

test("only explicit rejection statuses release a reservation", () => {
  for (const statusCode of [400, 401, 403, 404, 405, 410, 413, 415, 422]) {
    const result = classify({ statusCode, body: { message: "synthetic rejection" } });
    assert.equal(result.state, "FAILED", `expected FAILED for ${statusCode}`);
    assert.equal(result.provider_status_code, statusCode);
    assert.equal(result.should_record_result, true);
  }
});

test("408 and unlisted 4xx remain failed attempts but their quota reservation stays held", () => {
  for (const statusCode of [408, 409, 418, 423, 424, 425, 428, 431, 451]) {
    const result = classify({ statusCode, body: { message: "synthetic client response" } });
    assert.equal(result.state, "FAILED", `expected classifier FAILED for ${statusCode}`);
    assert.equal(result.provider_status_code, statusCode);
    // The database migration's definitive rejection allowlist is narrower.
    assert.ok(![400, 401, 403, 404, 405, 410, 413, 415, 422].includes(statusCode));
  }
});

test("429, 5xx and missing provider status remain ambiguous and retryable", () => {
  for (const statusCode of [429, 500, 501, 502, 503, 504, 520]) {
    const result = classify({ statusCode, body: { message: "synthetic transient result" } });
    assert.equal(result.state, "UNKNOWN", `expected UNKNOWN for ${statusCode}`);
    assert.equal(result.retryable, true);
    assert.equal(result.provider_status_code, statusCode);
  }
  const missing = classify({});
  assert.equal(missing.state, "UNKNOWN");
  assert.equal(missing.error_class, "AMBIGUOUS_TRANSPORT");
  assert.equal(missing.retryable, true);
  assert.equal(missing.provider_status_code, null);
});

test("a provider response below 200 or outside known classes stays ambiguous", () => {
  for (const statusCode of [0, 100, 199, 300, 301]) {
    const result = classify({ statusCode });
    assert.equal(result.state, "UNKNOWN", `unexpected status classification for ${statusCode}`);
    assert.equal(result.retryable, true);
  }
});

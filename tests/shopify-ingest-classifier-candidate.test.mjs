import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const source = readFileSync(new URL("../n8n/shopify-ingest-classifier-candidate.js", import.meta.url), "utf8");
const validate = {
  correlation_id: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
  event: { event_id: "delivery-001" },
};
const run = new Function("$json", "$", source);

function classify(response) {
  return run(response, (name) => {
    assert.equal(name, "Validate & Normalize");
    return { item: { json: validate } };
  });
}

test("new Shopify event is accepted only with durable replay job", () => {
  const result = classify({
    statusCode: 200,
    body: [{
      webhook_id: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb",
      replay_job_id: "cccccccc-cccc-4ccc-8ccc-cccccccccccc",
      replay_job_status: "QUEUED",
      processing_status: "PROCESSING",
      is_duplicate: false,
      should_process: true,
    }],
  });
  assert.equal(result.__http, 200);
  assert.equal(result.__proceed, true);
  assert.equal(result.__replay_job_id, "cccccccc-cccc-4ccc-8ccc-cccccccccccc");
});

test("in-flight duplicate is acknowledged only when a durable job remains active", () => {
  const result = classify({
    statusCode: 200,
    body: [{
      webhook_id: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb",
      replay_job_id: "cccccccc-cccc-4ccc-8ccc-cccccccccccc",
      replay_job_status: "RETRY_WAIT",
      processing_status: "PROCESSING",
      is_duplicate: true,
      should_process: false,
    }],
  });
  assert.equal(result.__http, 200);
  assert.equal(result.__proceed, false);
  assert.equal(result.__body.status, "already_processing");
});

test("processed duplicate is acknowledged without creating another replay job", () => {
  const result = classify({
    statusCode: 200,
    body: [{
      webhook_id: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb",
      replay_job_id: null,
      replay_job_status: null,
      processing_status: "PROCESSED",
      is_duplicate: true,
      should_process: false,
    }],
  });
  assert.equal(result.__http, 200);
  assert.equal(result.__body.status, "duplicate");
});

test("missing or terminal replay job fails closed with retryable 503", () => {
  for (const row of [
    { webhook_id: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb", processing_status: "PROCESSING", should_process: true },
    { webhook_id: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb", replay_job_id: "cccccccc-cccc-4ccc-8ccc-cccccccccccc", replay_job_status: "DEAD_LETTER", processing_status: "PROCESSING", should_process: false },
  ]) {
    const result = classify({ statusCode: 200, body: [row] });
    assert.equal(result.__http, 503);
    assert.equal(result.__proceed, false);
  }
});

test("generic 409 is never treated as a successful duplicate", () => {
  const result = classify({ statusCode: 409, body: { error: "conflict" } });
  assert.equal(result.__http, 503);
  assert.equal(result.__body.status, "temporarily_unavailable");
});

test("RPC transport failures remain retryable", () => {
  const result = classify({ error: { message: "network unavailable" } });
  assert.equal(result.__http, 503);
});

test("ingest RPC authorization and endpoint failures are retryable, not bad-HMAC responses", () => {
  for (const statusCode of [401, 403, 404, 408, 429, 500]) {
    const result = classify({ statusCode, body: { error: "synthetic" } });
    assert.equal(result.__http, 503, `expected retryable 503 for upstream ${statusCode}`);
  }
});

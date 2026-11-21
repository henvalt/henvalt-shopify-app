import test from "node:test";
import assert from "node:assert/strict";
import { classifyShopifyIngressAck } from "../n8n/shopify-ingest-ack-classifier-candidate.mjs";

const WEBHOOK = "11111111-1111-4111-8111-111111111111";
const JOB = "22222222-2222-4222-8222-222222222222";
const accepted = (overrides = {}) => ({
  http_status: 200, result_status: "accepted", webhook_id: WEBHOOK,
  replay_job_id: JOB, replay_job_status: "QUEUED",
  processing_status: "PROCESSING", ...overrides,
});

test("accepted and in-flight duplicate deliveries require a durable active replay job", () => {
  for (const result_status of ["accepted", "replay_accepted"]) {
    const result = classifyShopifyIngressAck(accepted({ result_status }));
    assert.equal(result.ok, true);
    assert.equal(result.http_status, 200);
    assert.equal(result.terminate_ingress, true);
  }
});

test("processed duplicate is acknowledged without requiring a new replay job", () => {
  const result = classifyShopifyIngressAck(accepted({
    result_status: "duplicate", replay_job_id: null, replay_job_status: null,
    processing_status: "PROCESSED",
  }));
  assert.equal(result.ok, true);
  assert.equal(result.body.status, "duplicate");
});

test("missing webhook ID, replay ID or active state never becomes HTTP 200", () => {
  for (const overrides of [
    { webhook_id: null },
    { replay_job_id: null },
    { replay_job_status: "DEAD_LETTER" },
    { replay_job_status: "SUCCEEDED" },
    { result_status: "unknown" },
  ]) {
    const result = classifyShopifyIngressAck(accepted(overrides));
    assert.equal(result.ok, false);
    assert.equal(result.http_status, 503);
    assert.equal(result.terminate_ingress, true);
  }
});

test("maps verifier, tenant and malformed-event outcomes to explicit statuses", () => {
  assert.equal(classifyShopifyIngressAck({ http_status: 401 }).http_status, 401);
  assert.equal(classifyShopifyIngressAck({ http_status: 404 }).http_status, 404);
  assert.equal(classifyShopifyIngressAck({ http_status: 422 }).http_status, 422);
  assert.equal(classifyShopifyIngressAck({ http_status: 503 }).http_status, 503);
});

test("legacy 409 or malformed RPC output cannot be treated as a duplicate", () => {
  assert.equal(classifyShopifyIngressAck({ http_status: 409 }).http_status, 503);
  assert.equal(classifyShopifyIngressAck({ http_status: 200, result_status: "duplicate" }).http_status, 503);
});

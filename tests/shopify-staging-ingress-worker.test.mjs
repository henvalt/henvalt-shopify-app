import test from "node:test";
import assert from "node:assert/strict";
import { createHmac } from "node:crypto";
import { handleStagingRequest } from "../cloudflare/staging-worker.js";

const secret = "synthetic-stage-shopify-secret";
const baseEnv = {
  SHOPIFY_API_SECRET: secret,
  N8N_INGEST_URL: "https://stage-n8n.example.test/webhook/henvalt/ingest-candidate-no-send",
  HENVALT_STAGE_N8N_HOST: "stage-n8n.example.test",
  HENVALT_STAGE_NO_SEND: "true",
  HENVALT_STAGE_PROVIDER_MODE: "stub",
};
const request = () => {
  const raw = JSON.stringify({ id: 123, test: true });
  const hmac = createHmac("sha256", secret).update(raw).digest("base64");
  return new Request("https://henvalt-shopify-ingress-staging-no-send.chmuhammadrehan18.workers.dev/shopify/webhooks", {
    method: "POST",
    headers: {
      "content-type": "application/json",
      "x-shopify-shop-domain": "henvalt-stage.myshopify.com",
      "x-shopify-topic": "checkouts/update",
      "x-shopify-hmac-sha256": hmac,
      "x-shopify-webhook-id": "synthetic-stage-webhook-1",
    },
    body: raw,
  });
};

test("staging ingress refuses to run without the explicit no-send guard before any upstream fetch", async () => {
  let calls = 0;
  const response = await handleStagingRequest(request(), { ...baseEnv, HENVALT_STAGE_NO_SEND: "false" }, async () => { calls++; });
  assert.equal(response.status, 503);
  assert.equal(calls, 0);
});

test("staging ingress refuses live provider mode before any upstream fetch", async () => {
  let calls = 0;
  const response = await handleStagingRequest(request(), { ...baseEnv, HENVALT_STAGE_PROVIDER_MODE: "live" }, async () => { calls++; });
  assert.equal(response.status, 503);
  assert.equal(calls, 0);
});

test("staging ingress refuses production n8n host and wrong replay path", async () => {
  for (const N8N_INGEST_URL of [
    "https://n8n.henvalt.com/webhook/henvalt/ingest-candidate-no-send",
    "https://henvalt26.app.n8n.cloud/webhook/henvalt/ingest-candidate-no-send",
    "https://stage-n8n.example.test/webhook/henvalt/ingest",
    "https://staging-n8n.invalid/webhook/henvalt/ingest-candidate-no-send",
    "https://unapproved-host.example.test/webhook/henvalt/ingest-candidate-no-send",
  ]) {
    let calls = 0;
    const response = await handleStagingRequest(request(), { ...baseEnv, N8N_INGEST_URL }, async () => { calls++; });
    assert.equal(response.status, 503, N8N_INGEST_URL);
    assert.equal(calls, 0, N8N_INGEST_URL);
  }
});

test("staging health reports a blocked configuration until all no-send prerequisites exist", async () => {
  const response = await handleStagingRequest(
    new Request("https://stage.example.test/health"),
    { ...baseEnv, N8N_INGEST_URL: "https://staging-n8n.invalid/webhook/henvalt/ingest-candidate-no-send" },
  );
  const body = await response.json();
  assert.equal(body.service, "henvalt-shopify-ingress-staging-no-send");
  assert.equal(body.configured, false);
  assert.equal(body.no_send, true);
  assert.equal(body.provider_mode, "stub");
});

test("valid staging configuration accepts only a durable webhook and replay-job acknowledgement", async () => {
  let calls = 0;
  const response = await handleStagingRequest(request(), baseEnv, async (url, init) => {
    calls++;
    assert.equal(url, baseEnv.N8N_INGEST_URL);
    assert.equal(init.method, "POST");
    assert.ok(init.headers instanceof Headers);
    assert.equal(init.headers.get("authorization"), null);
    return Response.json({
      status: "accepted",
      webhook_id: "11111111-1111-4111-8111-111111111111",
      replay_job_id: "22222222-2222-4222-8222-222222222222",
      replay_job_status: "QUEUED",
    }, { status: 200 });
  });
  assert.equal(response.status, 200);
  assert.equal(calls, 1);
  const body = await response.json();
  assert.equal(body.status, "accepted");
  assert.equal(body.replay_job_status, "QUEUED");
});

test("valid staging configuration rejects generic upstream 2xx responses", async () => {
  const response = await handleStagingRequest(request(), baseEnv, async () => new Response(null, { status: 204 }));
  assert.equal(response.status, 503);
});

test("staging ingress refuses a missing or mismatched exact n8n host allowlist", async () => {
  for (const env of [
    { ...baseEnv, HENVALT_STAGE_N8N_HOST: "" },
    { ...baseEnv, HENVALT_STAGE_N8N_HOST: "different-stage.example.test" },
    { ...baseEnv, N8N_INGEST_URL: "https://prod-stage.example.test/webhook/henvalt/ingest-candidate-no-send", HENVALT_STAGE_N8N_HOST: "prod-stage.example.test" },
  ]) {
    let calls = 0;
    const response = await handleStagingRequest(request(), env, async () => { calls++; });
    assert.equal(response.status, 503);
    assert.equal(calls, 0);
  }
});

import test from "node:test";
import assert from "node:assert/strict";
import { handleStagingSupabaseIngress, STAGING_SUPABASE_INGRESS_TIMEOUT_MS } from "../cloudflare/staging-supabase-ingress-worker.js";

const env = {
  SUPABASE_URL: "https://xidhtmrfvsgfmyltjuja.supabase.co",
  HENVALT_STAGE_NO_SEND: "true",
};
const webhookId = "123e4567-e89b-42d3-a456-426614174000";
const replayId = "123e4567-e89b-42d3-a456-426614174001";
function webhookRequest(body = '{"id":42}', headers = {}) {
  return new Request("https://worker.example/shopify/webhooks", {
    method: "POST",
    headers: {
      "content-type": "application/json",
      "x-shopify-shop-domain": "fixture-shop.myshopify.com",
      "x-shopify-topic": "checkouts/update",
      "x-shopify-hmac-sha256": "synthetic-hmac",
      "x-shopify-webhook-id": "fixture-delivery-42",
      ...headers,
    },
    body,
  });
}

test("upstream timeout stays below Shopify's five-second webhook response budget", () => {
  assert.equal(STAGING_SUPABASE_INGRESS_TIMEOUT_MS, 4300);
});

test("health reports the isolated staging identity and no-send boundary", async () => {
  const response = await handleStagingSupabaseIngress(new Request("https://worker.example/health"), env);
  const body = await response.json();
  assert.equal(response.status, 200);
  assert.equal(body.configured, true);
  assert.equal(body.no_send, true);
  assert.equal(body.hmac_verification, "supabase_edge_function");
});

test("health fails closed for production, arbitrary projects, and missing no-send guard", async () => {
  for (const config of [
    { ...env, SUPABASE_URL: "https://ocyplckdojdubyrsxcxa.supabase.co" },
    { ...env, SUPABASE_URL: "https://attacker.example" },
    { ...env, HENVALT_STAGE_NO_SEND: "false" },
  ]) {
    const response = await handleStagingSupabaseIngress(new Request("https://worker.example/health"), config);
    assert.equal((await response.json()).configured, false);
  }
});

test("forwards exact raw bytes to the fixed staging Edge Function with only allowlisted Shopify headers", async () => {
  let captured;
  const raw = '{"id":42, "raw":"bytes must stay exact"}';
  const response = await handleStagingSupabaseIngress(
    webhookRequest(raw, {
      "x-shopify-event-id": "event-42",
      "x-shopify-api-version": "2026-10",
      authorization: "Bearer attacker",
      "x-internal-secret": "must-not-forward",
    }),
    env,
    async (url, init) => {
      captured = { url, init, body: await new Response(init.body).text() };
      return Response.json({
        status: "accepted",
        webhook_id: webhookId,
        replay_job_id: replayId,
        replay_job_status: "QUEUED",
        processing_status: "PROCESSING",
        correlation_id: webhookId,
      });
    },
  );
  assert.equal(response.status, 200);
  assert.equal(captured.url, env.SUPABASE_URL + "/functions/v1/henvalt-shopify-webhook-ingress");
  assert.equal(captured.body, raw);
  assert.equal(captured.init.headers.get("authorization"), null);
  assert.equal(captured.init.headers.get("x-internal-secret"), null);
  assert.equal(captured.init.headers.get("x-shopify-hmac-sha256"), "synthetic-hmac");
  assert.equal(captured.init.headers.get("x-shopify-event-id"), "event-42");
  assert.equal((await response.json()).replay_job_id, replayId);
});

test("does not acknowledge unless the Edge Function proves a durable active replay job", async () => {
  const response = await handleStagingSupabaseIngress(webhookRequest(), env,
    async () => Response.json({ status: "accepted", webhook_id: webhookId }));
  assert.equal(response.status, 503);
});

test("acknowledges only a duplicate already marked processed", async () => {
  const response = await handleStagingSupabaseIngress(webhookRequest(), env,
    async () => Response.json({ status: "duplicate", webhook_id: webhookId, processing_status: "PROCESSED" }));
  assert.equal(response.status, 200);
  assert.equal((await response.json()).status, "duplicate");
});

test("preserves only intentional HMAC, tenant and malformed-event rejections", async (t) => {
  for (const [name, upstreamStatus, error, expectedStatus] of [
    ["bad HMAC", 401, "invalid_hmac", 401],
    ["unknown tenant", 404, "unknown_tenant", 404],
    ["malformed event", 422, "malformed_event", 422],
  ]) {
    await t.test(name, async () => {
      const response = await handleStagingSupabaseIngress(webhookRequest(), env,
        async () => Response.json({ error }, { status: upstreamStatus }));
      assert.equal(response.status, expectedStatus);
      assert.deepEqual(await response.json(), { error });
    });
  }
});

test("internal Edge Function errors stay retryable and do not leak details", async () => {
  const response = await handleStagingSupabaseIngress(webhookRequest(), env,
    async () => Response.json({ error: "secret_configuration_detail" }, { status: 500 }));
  assert.equal(response.status, 503);
  assert.deepEqual(await response.json(), { error: "durable_ingest_unavailable" });
});

test("rejects malformed Shopify headers and oversized bodies before upstream access", async () => {
  let calls = 0;
  const fetchImpl = async () => { calls++; throw new Error("must not call"); };
  const badShop = await handleStagingSupabaseIngress(webhookRequest("{}", {
    "x-shopify-shop-domain": "evil.example",
  }), env, fetchImpl);
  assert.equal(badShop.status, 400);
  const badTopic = await handleStagingSupabaseIngress(webhookRequest("{}", {
    "x-shopify-topic": "not a topic",
  }), env, fetchImpl);
  assert.equal(badTopic.status, 400);
  const oversized = await handleStagingSupabaseIngress(webhookRequest("x".repeat(1_000_001)), env, fetchImpl);
  assert.equal(oversized.status, 413);
  assert.equal(calls, 0);
});

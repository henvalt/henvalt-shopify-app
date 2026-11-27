import test from "node:test";
import assert from "node:assert/strict";
import { handleStagingSupabaseIngress, STAGING_SUPABASE_INGRESS_TIMEOUT_MS } from "../cloudflare/staging-supabase-ingress-worker.js";

const secret = "staging-ingress-shared-secret-".padEnd(48, "x");
const env = {
  SUPABASE_URL: "https://xidhtmrfvsgfmyltjuja.supabase.co",
  HENVALT_INGRESS_SHARED_SECRET: secret,
  HENVALT_STAGE_NO_SEND: "true",
};
const uuid = "123e4567-e89b-42d3-a456-426614174000";
const jobId = "123e4567-e89b-42d3-a456-426614174001";
function webhookRequest(body = '{"id":42}', headers = {}) {
  return new Request("https://worker.example/shopify/webhooks", {
    method: "POST",
    headers: {
      "content-type": "application/json",
      "x-shopify-shop-domain": "fixture-shop.myshopify.com",
      "x-shopify-topic": "checkouts/update",
      "x-shopify-hmac-sha256": "opaque-shopify-signature",
      "x-shopify-webhook-id": "fixture-delivery-42",
      ...headers,
    },
    body,
  });
}

test("Supabase ingress upstream timeout stays inside Shopify's five-second response budget", () => {
  assert.equal(STAGING_SUPABASE_INGRESS_TIMEOUT_MS, 3500);
});

test("health reports exact staging project and no-send mode", async () => {
  const response = await handleStagingSupabaseIngress(new Request("https://worker.example/health"), env);
  const body = await response.json();
  assert.equal(response.status, 200);
  assert.equal(body.configured, true);
  assert.equal(body.no_send, true);
  assert.equal(body.runtime, "supabase-edge-function-durable-ingest-rpc");
});

test("rejects wrong Supabase project before upstream request", async () => {
  let calls = 0;
  const response = await handleStagingSupabaseIngress(webhookRequest(),
    { ...env, SUPABASE_URL: "https://ocyplckdojdubyrsxcxa.supabase.co" },
    async () => { calls++; throw new Error("must not call"); });
  assert.equal(response.status, 503);
  assert.equal(calls, 0);
});

test("forwards raw signed body only to the staging ingress Edge Function", async () => {
  let captured;
  const raw = '{"id":42}';
  const response = await handleStagingSupabaseIngress(
    webhookRequest(raw, { "x-shopify-event-id": "event-42", authorization: "Bearer attacker" }),
    env,
    async (url, init) => {
      captured = { url, init, body: await new Response(init.body).text() };
      return Response.json({
        status: "accepted", webhook_id: uuid, replay_job_id: jobId,
        replay_job_status: "QUEUED", processing_status: "PROCESSING",
      });
    },
  );
  assert.equal(response.status, 200);
  assert.equal(captured.url, env.SUPABASE_URL + "/functions/v1/henvalt-shopify-webhook-ingress");
  assert.equal(captured.init.headers.get("authorization"), "Bearer " + secret);
  assert.equal(captured.init.headers.get("x-shopify-hmac-sha256"), "opaque-shopify-signature");
  assert.equal(captured.init.headers.get("authorization"), "Bearer " + secret);
  assert.equal(captured.body, raw);
  assert.equal((await response.json()).replay_job_id, jobId);
});

test("does not acknowledge without a durable active replay job", async () => {
  const response = await handleStagingSupabaseIngress(webhookRequest(), env,
    async () => Response.json({ status: "accepted", webhook_id: uuid }));
  assert.equal(response.status, 503);
});

test("does not acknowledge generic upstream 2xx", async () => {
  const response = await handleStagingSupabaseIngress(webhookRequest(), env,
    async () => new Response(null, { status: 204 }));
  assert.equal(response.status, 503);
});

test("preserves only explicit Shopify event rejection statuses from the Supabase boundary", async (t) => {
  const cases = [
    ["invalid HMAC", 401, "invalid_hmac", 401, "invalid_hmac"],
    ["unknown tenant", 404, "unknown_tenant", 404, "unknown_tenant"],
    ["malformed event", 422, "malformed_event", 422, "malformed_event"],
  ];
  for (const [name, upstreamStatus, upstreamError, expectedStatus, expectedError] of cases) {
    await t.test(name, async () => {
      const response = await handleStagingSupabaseIngress(webhookRequest(), env,
        async () => Response.json({ error: upstreamError }, { status: upstreamStatus }));
      assert.equal(response.status, expectedStatus);
      assert.deepEqual(await response.json(), { error: expectedError });
    });
  }
});

test("does not misreport ingress worker authentication failure as invalid Shopify HMAC", async () => {
  const response = await handleStagingSupabaseIngress(webhookRequest(), env,
    async () => Response.json({ error: "unauthorized_ingress_worker" }, { status: 401 }));
  assert.equal(response.status, 503);
  assert.deepEqual(await response.json(), { error: "durable_ingest_unavailable" });
});

test("unexpected upstream errors remain retryable and do not leak internal details", async () => {
  const response = await handleStagingSupabaseIngress(webhookRequest(), env,
    async () => Response.json({ error: "secret_configuration_detail" }, { status: 500 }));
  assert.equal(response.status, 503);
  assert.deepEqual(await response.json(), { error: "durable_ingest_unavailable" });
});

test("rejects malformed JSON before reaching Supabase", async () => {
  let calls = 0;
  const response = await handleStagingSupabaseIngress(webhookRequest("{broken"), env,
    async () => { calls++; throw new Error("must not call"); });
  assert.equal(response.status, 422);
  assert.equal(calls, 0);
});

test("health fails closed when no-send flag or shared secret is absent", async () => {
  for (const config of [{ ...env, HENVALT_STAGE_NO_SEND: "false" }, { ...env, HENVALT_INGRESS_SHARED_SECRET: "" }]) {
    const response = await handleStagingSupabaseIngress(new Request("https://worker.example/health"), config);
    assert.equal((await response.json()).configured, false);
  }
});

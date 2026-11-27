import test from "node:test";
import assert from "node:assert/strict";
import { handleShopifyWebhookIngress } from "../supabase/functions/henvalt-shopify-webhook-ingress/handler.mjs";

const shared = "staging-ingress-shared-secret-".padEnd(48, "x");
const service = "staging-service-role-key-".padEnd(60, "y");
const env = {
  SUPABASE_URL: "https://xidhtmrfvsgfmyltjuja.supabase.co",
  SUPABASE_SERVICE_ROLE_KEY: service,
  HENVALT_INGRESS_SHARED_SECRET: shared,
  HENVALT_STAGE_NO_SEND: "true",
};
const webhookId = "123e4567-e89b-42d3-a456-426614174000";
const replayId = "123e4567-e89b-42d3-a456-426614174001";
function request(body = '{"id":42}', authorization = "Bearer " + shared) {
  return new Request("https://staging.supabase.co/", {
    method: "POST",
    headers: {
      authorization,
      "content-type": "application/json",
      "x-shopify-shop-domain": "fixture-shop.myshopify.com",
      "x-shopify-topic": "checkouts/update",
      "x-shopify-hmac-sha256": "shopify-hmac",
      "x-shopify-webhook-id": "fixture-delivery",
      "x-shopify-event-id": "fixture-event",
    },
    body,
  });
}

test("rejects missing or invalid Worker shared secret before database call", async () => {
  let calls = 0;
  const response = await handleShopifyWebhookIngress(request('{"id":42}', "Bearer wrong"), env,
    async () => { calls++; throw new Error("must not call"); });
  assert.equal(response.status, 401);
  assert.equal(calls, 0);
});

test("rejects a production Supabase project in staging mode", async () => {
  const response = await handleShopifyWebhookIngress(request(), {
    ...env, SUPABASE_URL: "https://ocyplckdojdubyrsxcxa.supabase.co",
  }, async () => { throw new Error("must not call"); });
  assert.equal(response.status, 503);
});

test("calls only the service-role-only durable ingress RPC and maps confirmed acceptance", async () => {
  let captured;
  const raw = '{"id":42}';
  const response = await handleShopifyWebhookIngress(request(raw), env, async (url, init) => {
    captured = { url, init, body: JSON.parse(init.body) };
    return Response.json([{
      http_status: 200, result_status: "accepted", webhook_id: webhookId,
      replay_job_id: replayId, replay_job_status: "QUEUED",
      processing_status: "PROCESSING", correlation_id: webhookId,
    }]);
  });
  assert.equal(response.status, 200);
  assert.equal(captured.url, env.SUPABASE_URL + "/rest/v1/rpc/receive_shopify_webhook_v1");
  assert.equal(captured.init.headers.authorization, "Bearer " + service);
  assert.equal(captured.init.headers["content-profile"], "henvalt");
  assert.equal(atob(captured.body.p_raw_body_base64), raw);
  assert.deepEqual(captured.body.p_payload, { id: 42 });
  assert.equal(captured.body.p_hmac, "shopify-hmac");
  assert.equal(captured.body.p_metadata.shopify_event_id, "fixture-event");
  const ack = await response.json();
  assert.equal(ack.replay_job_id, replayId);
  assert.equal(ack.replay_job_status, "QUEUED");
});

test("returns retryable 503 when the RPC cannot prove durable replay", async () => {
  const response = await handleShopifyWebhookIngress(request(), env,
    async () => Response.json([{
      http_status: 200, result_status: "accepted", webhook_id: webhookId,
      replay_job_id: null, replay_job_status: null,
    }]));
  assert.equal(response.status, 503);
});

test("maps HMAC failure from database verification to 401", async () => {
  const response = await handleShopifyWebhookIngress(request(), env,
    async () => Response.json([{ http_status: 401, result_status: "invalid_hmac" }]));
  assert.equal(response.status, 401);
});

test("returns a duplicate acknowledgement only with a durable processed webhook", async () => {
  const response = await handleShopifyWebhookIngress(request(), env,
    async () => Response.json([{
      http_status: 200, result_status: "duplicate", webhook_id: webhookId,
      processing_status: "PROCESSED", correlation_id: webhookId,
    }]));
  assert.equal(response.status, 200);
  assert.equal((await response.json()).status, "duplicate");
});

test("rejects malformed payload before database access", async () => {
  let calls = 0;
  const response = await handleShopifyWebhookIngress(request("{"), env,
    async () => { calls++; throw new Error("must not call"); });
  assert.equal(response.status, 422);
  assert.equal(calls, 0);
});

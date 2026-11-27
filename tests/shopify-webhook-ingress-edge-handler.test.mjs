import test from "node:test";
import assert from "node:assert/strict";
import { createHmac } from "node:crypto";
import { handleShopifyWebhookIngress } from "../supabase/functions/henvalt-shopify-webhook-ingress/handler.mjs";

const service = "staging-service-role-key-".padEnd(60, "y");
const shopifySecret = "test-shopify-app-secret";
const env = {
  SUPABASE_URL: "https://xidhtmrfvsgfmyltjuja.supabase.co",
  SUPABASE_SERVICE_ROLE_KEY: service,
  SHOPIFY_API_SECRET: shopifySecret,
  HENVALT_STAGE_NO_SEND: "true",
};
const webhookId = "123e4567-e89b-42d3-a456-426614174000";
const replayId = "123e4567-e89b-42d3-a456-426614174001";
function request(body = '{"id":42}', hmacOverride) {
  const hmac = hmacOverride ?? createHmac("sha256", shopifySecret).update(body).digest("base64");
  return new Request("https://staging.supabase.co/", {
    method: "POST",
    headers: {
      "content-type": "application/json",
      "x-shopify-shop-domain": "fixture-shop.myshopify.com",
      "x-shopify-topic": "checkouts/update",
      "x-shopify-hmac-sha256": hmac,
      "x-shopify-webhook-id": "fixture-delivery",
      "x-shopify-event-id": "fixture-event",
    },
    body,
  });
}

test("rejects a production Supabase project in staging mode", async () => {
  const response = await handleShopifyWebhookIngress(request(), {
    ...env, SUPABASE_URL: "https://ocyplckdojdubyrsxcxa.supabase.co",
  }, async () => { throw new Error("must not call"); });
  assert.equal(response.status, 503);
});

test("rejects invalid Shopify HMAC before database call", async () => {
  let calls = 0;
  const response = await handleShopifyWebhookIngress(request('{"id":42}', "invalid-hmac"), env,
    async () => { calls++; throw new Error("must not call"); });
  assert.equal(response.status, 401);
  assert.equal(calls, 0);
});

test("calls the edge-verified service-role-only RPC and maps confirmed acceptance", async () => {
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
  assert.equal(captured.url, env.SUPABASE_URL + "/rest/v1/rpc/receive_shopify_webhook_edge_verified_v1");
  assert.equal(captured.init.headers.authorization, "Bearer " + service);
  assert.equal(captured.init.headers["content-profile"], "henvalt");
  assert.equal(atob(captured.body.p_raw_body_base64), raw);
  assert.deepEqual(captured.body.p_payload, { id: 42 });
  assert.equal(captured.body.p_hmac, undefined);
  assert.equal(captured.body.p_metadata.ingress_hmac_verified, true);
  assert.equal(captured.body.p_metadata.hmac_verifier, "shopify_edge_function");
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

test("returns a duplicate acknowledgement only with a durable processed webhook", async () => {
  const response = await handleShopifyWebhookIngress(request(), env,
    async () => Response.json([{
      http_status: 200, result_status: "duplicate", webhook_id: webhookId,
      processing_status: "PROCESSED", correlation_id: webhookId,
    }]));
  assert.equal(response.status, 200);
  assert.equal((await response.json()).status, "duplicate");
});

test("rejects malformed payload before database access even with valid HMAC", async () => {
  let calls = 0;
  const response = await handleShopifyWebhookIngress(request("{"), env,
    async () => { calls++; throw new Error("must not call"); });
  assert.equal(response.status, 422);
  assert.equal(calls, 0);
});

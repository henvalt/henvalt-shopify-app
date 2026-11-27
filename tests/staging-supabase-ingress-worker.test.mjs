import test from "node:test";
import assert from "node:assert/strict";
import { handleStagingSupabaseIngress } from "../cloudflare/staging-supabase-ingress-worker.js";

const env = {
  SUPABASE_URL: "https://xidhtmrfvsgfmyltjuja.supabase.co",
  SUPABASE_SERVICE_ROLE_KEY: "s".repeat(60),
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

test("health reports exact staging binding and no-send mode", async () => {
  const response = await handleStagingSupabaseIngress(
    new Request("https://worker.example/health"), env,
  );
  assert.equal(response.status, 200);
  const body = await response.json();
  assert.equal(body.configured, true);
  assert.equal(body.no_send, true);
  assert.equal(body.runtime, "supabase-durable-ingest-rpc");
});

test("rejects wrong Supabase project before any upstream request", async () => {
  let calls = 0;
  const response = await handleStagingSupabaseIngress(
    webhookRequest(), { ...env, SUPABASE_URL: "https://ocyplckdojdubyrsxcxa.supabase.co" },
    async () => { calls++; throw new Error("must not call"); },
  );
  assert.equal(response.status, 503);
  assert.equal(calls, 0);
});

test("sends raw-body proof and metadata to the durable staging RPC", async () => {
  let captured;
  const response = await handleStagingSupabaseIngress(
    webhookRequest('{"id":42}', { "x-shopify-event-id": "event-42" }),
    env,
    async (url, init) => {
      captured = { url, init, body: JSON.parse(init.body) };
      return Response.json([{
        http_status: 200, result_status: "accepted", webhook_id: uuid,
        replay_job_id: jobId, replay_job_status: "QUEUED",
        processing_status: "PROCESSING", correlation_id: uuid,
      }]);
    },
  );
  assert.equal(response.status, 200);
  assert.match(captured.url, /\/rest\/v1\/rpc\/receive_shopify_webhook_v1$/);
  assert.equal(captured.init.headers["content-profile"], "henvalt");
  assert.equal(captured.body.p_shop_domain, "fixture-shop.myshopify.com");
  assert.equal(captured.body.p_delivery_id, "fixture-delivery-42");
  assert.equal(captured.body.p_hmac, "opaque-shopify-signature");
  assert.equal(atob(captured.body.p_raw_body_base64), '{"id":42}');
  assert.deepEqual(captured.body.p_payload, { id: 42 });
  assert.equal(captured.body.p_metadata.shopify_event_id, "event-42");
  assert.equal((await response.json()).replay_job_id, jobId);
});

test("does not acknowledge an accepted webhook without a durable active replay job", async () => {
  const response = await handleStagingSupabaseIngress(
    webhookRequest(), env,
    async () => Response.json([{
      http_status: 200, result_status: "accepted", webhook_id: uuid,
      replay_job_id: null, replay_job_status: null,
    }]),
  );
  assert.equal(response.status, 503);
});

test("maps database HMAC rejection to 401 and never claims acceptance", async () => {
  const response = await handleStagingSupabaseIngress(
    webhookRequest(), env,
    async () => Response.json([{
      http_status: 401, result_status: "invalid_hmac",
    }]),
  );
  assert.equal(response.status, 401);
  assert.deepEqual(await response.json(), { error: "invalid_hmac" });
});

test("only acknowledges a durable processed duplicate with a webhook ID", async () => {
  const response = await handleStagingSupabaseIngress(
    webhookRequest(), env,
    async () => Response.json([{
      http_status: 200, result_status: "duplicate", webhook_id: uuid,
      should_process: false, processing_status: "PROCESSED",
      correlation_id: uuid,
    }]),
  );
  assert.equal(response.status, 200);
  assert.equal((await response.json()).status, "duplicate");
});

test("rejects malformed JSON before reaching Supabase", async () => {
  let calls = 0;
  const response = await handleStagingSupabaseIngress(
    webhookRequest("{broken"), env,
    async () => { calls++; throw new Error("must not call"); },
  );
  assert.equal(response.status, 422);
  assert.equal(calls, 0);
});

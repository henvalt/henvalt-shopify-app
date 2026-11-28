import test from "node:test";
import assert from "node:assert/strict";
import { createRecoveryExecutorHandler, STAGING_SUPABASE_URL, parseJsonContent } from "../supabase/functions/henvalt-recovery-executor/handler.mjs";

const key = "test-service-role-secret";
const makeRequest = (token = key, body = {}) => new Request("https://staging.test/functions/v1/henvalt-recovery-executor", {
  method: "POST",
  headers: token ? { authorization: "Bearer " + token, "content-type": "application/json" } : {},
  body: JSON.stringify(body),
});
const create = (overrides = {}) => createRecoveryExecutorHandler({
  supabaseUrl: STAGING_SUPABASE_URL,
  serviceRoleKey: key,
  publicActionsBaseUrl: "https://actions.staging.example.test",
  fetchImpl: async () => { throw new Error("unexpected_network_call"); },
  ...overrides,
});

test("rejects non-POST and unauthenticated requests before database access", async () => {
  let calls = 0;
  const run = create({ fetchImpl: async () => { calls++; throw new Error("unexpected"); } });
  assert.equal((await run(new Request("https://staging.test", { method: "GET" }))).status, 405);
  assert.equal((await run(makeRequest("wrong"))).status, 401);
  assert.equal(calls, 0);
});

test("fails closed when pointed at production", async () => {
  let calls = 0;
  const run = create({
    supabaseUrl: "https://ocyplckdojdubyrsxcxa.supabase.co",
    fetchImpl: async () => { calls++; throw new Error("unexpected"); },
  });
  assert.equal((await run(makeRequest())).status, 503);
  assert.equal(calls, 0);
});

test("returns IDLE when no execute_intervention job is available", async () => {
  const run = create({ fetchImpl: async (url) => {
    assert.ok(url.endsWith("/rpc/claim_next_job"));
    return Response.json([]);
  }});
  const response = await run(makeRequest());
  assert.equal(response.status, 200);
  assert.deepEqual(await response.json(), { state: "IDLE", processed: 0 });
});

test("only claims execute_intervention jobs and never calls delivery/provider when idle", async () => {
  const calls = [];
  const run = create({ fetchImpl: async (url, options) => {
    calls.push({ url, body: options?.body ? JSON.parse(options.body) : null });
    return Response.json([]);
  }});
  await run(makeRequest());
  assert.deepEqual(calls[0].body.p_job_types, ["execute_intervention"]);
  assert.equal(calls.length, 1);
  assert.equal(calls.some(c => c.url.includes("mailer") || c.url.includes("groq")), false);
});

test("requires a configured HTTPS public action origin before creating tokens", async () => {
  const calls = [];
  const jobId = "11111111-1111-4111-8111-111111111111";
  const interventionId = "22222222-2222-4222-8222-222222222222";
  const run = create({
    publicActionsBaseUrl: "http://not-secure.example",
    fetchImpl: async (url, options) => {
      const rpc = url.split("/rpc/")[1];
      calls.push(rpc);
      if (rpc === "claim_next_job") return Response.json([{ id: jobId, payload: { intervention_id: interventionId }, correlation_id: null }]);
      if (rpc === "claim_intervention_for_send") return Response.json([{ claim_state: "CLAIMED" }]);
      if (rpc === "get_recovery_worker_context") return Response.json({
        context_found: true, tenant_active: true, shop_connection_active: true, intervention_status: "SENDING",
        recovery_active: true, opportunity_open: true, order_recovered: false, consent_valid: true,
        recipient: "customer@example.test", channel: "EMAIL", sender_reference: "hello@store.example",
        sender_configured: true, scheduled_at: new Date().toISOString(), flow_delay_minutes: 60,
        checkout_updated_at: new Date(Date.now() - 7200000).toISOString(), suppression_exists: false,
        destination_url: "https://store.example/checkout/abc", recovery_type: "ABANDONED_CHECKOUT",
      });
      if (rpc === "resolve_intervention_send_failure") return Response.json(true);
      if (rpc === "retry_job") return Response.json(true);
      throw new Error("unexpected " + rpc);
    },
  });
  const response = await run(makeRequest());
  assert.equal(response.status, 200);
  assert.deepEqual(await response.json(), { state: "RETRY_SCHEDULED", reason: "public_actions_endpoint_not_configured" });
  assert.equal(calls.includes("create_tracking_token"), false);
  assert.equal(calls.includes("create_unsubscribe_token"), false);
});

test("accepts only exact, bounded JSON copy without URLs", () => {
  const valid = JSON.stringify({ subject: "A note for you", opening: "Hi there,", body: "Your cart is ready.", cta_text: "Return to your cart" });
  assert.deepEqual(parseJsonContent(valid), JSON.parse(valid));
  assert.equal(parseJsonContent(JSON.stringify({ subject: "A note", opening: "", body: "Visit https://bad.example", cta_text: "Return" })), null);
  assert.equal(parseJsonContent(JSON.stringify({ subject: "A note", opening: "", body: "Hello", cta_text: "Return", extra: "not allowed" })), null);
  assert.equal(parseJsonContent("not-json"), null);
  assert.equal(parseJsonContent("x".repeat(12001)), null);
});


test("creates one staged delivery request through the AI gateway without calling MailerSend", async () => {
  const calls = [];
  const jobId = "11111111-1111-4111-8111-111111111111";
  const interventionId = "22222222-2222-4222-8222-222222222222";
  const trackingId = "33333333-3333-4333-8333-333333333333";
  const unsubscribeId = "44444444-4444-4444-8444-444444444444";
  const messageId = "55555555-5555-4555-8555-555555555555";
  const deliveryId = "66666666-6666-4666-8666-666666666666";
  const run = create({
    workerId: () => "test-worker",
    now: () => Date.now(),
    fetchImpl: async (url, options = {}) => {
      calls.push({ url, options });
      if (url.endsWith("/rpc/claim_next_job")) return Response.json([{
        id: jobId, tenant_id: "77777777-7777-4777-8777-777777777777",
        payload: { intervention_id: interventionId }, correlation_id: "88888888-8888-4888-8888-888888888888",
      }]);
      if (url.endsWith("/rpc/claim_intervention_for_send")) return Response.json([{ claim_state: "CLAIMED" }]);
      if (url.endsWith("/rpc/get_recovery_worker_context")) return Response.json({
        context_found: true,
        tenant_id: "77777777-7777-4777-8777-777777777777",
        intervention_id: interventionId,
        tenant_active: true,
        shop_connection_active: true,
        intervention_status: "SENDING",
        recovery_active: true,
        opportunity_open: true,
        order_recovered: false,
        consent_valid: true,
        recipient: "customer@example.test",
        channel: "EMAIL",
        sender_reference: "hello@store.example",
        sender_configured: true,
        delivery_mode: "PLATFORM",
        scheduled_at: new Date(Date.now() - 60000).toISOString(),
        flow_delay_minutes: 60,
        checkout_updated_at: new Date(Date.now() - 7200000).toISOString(),
        suppression_exists: false,
        destination_url: "https://store.example/checkouts/abc",
        recovery_type: "ABANDONED_CHECKOUT",
        store_name: "Example Store",
        customer_first_name: "Sam",
        step_number: 1,
        email_branding: {},
      });
      if (url.includes("/rest/v1/delivery_requests?")) return Response.json([]);
      if (url.endsWith("/rpc/create_tracking_token")) return Response.json([{ tracking_token_id: trackingId, token: "tracking-secret" }]);
      if (url.endsWith("/rpc/create_unsubscribe_token")) return Response.json([{ unsubscribe_token_id: unsubscribeId, token: "unsubscribe-secret" }]);
      if (url.endsWith("/functions/v1/henvalt-groq-generate")) {
        const body = JSON.parse(options.body);
        assert.equal(body.model, "openai/gpt-oss-120b");
        assert.equal(body.response_format.type, "json_object");
        return Response.json({ choices: [{ message: { content: JSON.stringify({
          subject: "A note for you",
          opening: "Hi Sam,",
          body: "Your checkout is ready whenever you are.",
          cta_text: "Return to checkout",
        }) } }] });
      }
      if (url.endsWith("/rpc/render_and_queue_message")) {
        const body = JSON.parse(options.body);
        assert.equal(body.p_intervention_id, interventionId);
        assert.ok(body.p_body.includes("tracking-secret"));
        assert.ok(body.p_body.includes("unsubscribe-secret"));
        return Response.json(messageId);
      }
      if (url.endsWith("/rpc/create_delivery_request")) {
        const body = JSON.parse(options.body);
        assert.equal(body.p_message_id, messageId);
        assert.equal(body.p_idempotency_key, "deliver:" + interventionId);
        assert.equal(body.p_provider, "MAILERSEND");
        return Response.json(deliveryId);
      }
      if (url.endsWith("/rpc/complete_job")) return Response.json(true);
      throw new Error("unexpected_url " + url);
    },
  });
  const response = await run(makeRequest());
  assert.equal(response.status, 200);
  assert.deepEqual(await response.json(), { state: "DELIVERY_REQUEST_CREATED", delivery_request_id: deliveryId });
  assert.ok(calls.some(c => c.url.endsWith("/functions/v1/henvalt-groq-generate")));
  assert.ok(calls.some(c => c.url.endsWith("/rpc/create_delivery_request")));
  assert.ok(calls.some(c => c.url.endsWith("/rpc/complete_job")));
  assert.equal(calls.some(c => c.url.includes("api.mailersend.com") || c.url.includes("henvalt-mailersend-delivery")), false);
});

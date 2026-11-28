import test from "node:test";
import assert from "node:assert/strict";
import { createDeliveryDispatcherHandler, STAGING_SUPABASE_URL } from "../supabase/functions/henvalt-delivery-dispatcher/handler.mjs";

const key = "test-service-role-key";
const request = (token = key) => new Request("https://staging.test/functions/v1/henvalt-delivery-dispatcher", {
  method: "POST",
  headers: token ? { authorization: "Bearer " + token } : {},
});
const create = (overrides = {}) => createDeliveryDispatcherHandler({
  supabaseUrl: STAGING_SUPABASE_URL,
  serviceRoleKey: key,
  fetchImpl: async () => { throw new Error("unexpected_network_call"); },
  ...overrides,
});

test("rejects unauthenticated and non-POST calls before database access", async () => {
  let calls = 0;
  const run = create({ fetchImpl: async () => { calls++; throw new Error("unexpected"); } });
  assert.equal((await run(new Request("https://staging.test", { method: "GET" }))).status, 405);
  assert.equal((await run(request("wrong"))).status, 401);
  assert.equal(calls, 0);
});

test("fails closed if configured for production", async () => {
  let calls = 0;
  const run = create({
    supabaseUrl: "https://ocyplckdojdubyrsxcxa.supabase.co",
    fetchImpl: async () => { calls++; throw new Error("unexpected"); },
  });
  assert.equal((await run(request())).status, 503);
  assert.equal(calls, 0);
});

test("provider sending interlock stops before selecting or processing delivery requests", async () => {
  const calls = [];
  const run = create({ fetchImpl: async (url, options = {}) => {
    calls.push({ url, options });
    if (url.includes("/provider_send_control")) {
      assert.equal(options.headers["accept-profile"], "henvalt");
      return Response.json([{ provider_sending_enabled: false }]);
    }
    throw new Error("unexpected " + url);
  }});
  const response = await run(request());
  assert.equal(response.status, 200);
  assert.deepEqual(await response.json(), { state: "PAUSED", reason: "provider_sending_disabled" });
  assert.equal(calls.length, 1);
  assert.ok(calls[0].url.includes("/provider_send_control"));
  assert.equal(calls[0].options.headers["accept-profile"], "henvalt");
});

test("returns IDLE when sending is enabled but no due delivery request exists", async () => {
  const calls = [];
  const run = create({ fetchImpl: async (url, options = {}) => {
    calls.push({ url, options });
    if (url.includes("/provider_send_control")) {
      assert.equal(options.headers["accept-profile"], "henvalt");
      return Response.json([{ provider_sending_enabled: true }]);
    }
    if (url.includes("/delivery_requests?")) return Response.json([]);
    throw new Error("unexpected " + url);
  }});
  const response = await run(request());
  assert.equal(response.status, 200);
  assert.deepEqual(await response.json(), { state: "IDLE", processed: 0 });
  assert.equal(calls.length, 2);
});

test("loads a trusted envelope, invokes protected delivery, and records ACCEPTED", async () => {
  const calls = [];
  const tenantId = "11111111-1111-4111-8111-111111111111";
  const interventionId = "22222222-2222-4222-8222-222222222222";
  const deliveryId = "33333333-3333-4333-8333-333333333333";
  const attemptId = "44444444-4444-4444-8444-444444444444";
  const run = create({ fetchImpl: async (url, options = {}) => {
    calls.push({ url, options });
    if (url.includes("/provider_send_control")) return Response.json([{ provider_sending_enabled: true }]);
    if (url.includes("/delivery_requests?")) return Response.json([{
      id: deliveryId, tenant_id: tenantId, intervention_id: interventionId,
      correlation_id: "55555555-5555-4555-8555-555555555555",
    }]);
    if (url.endsWith("/rpc/get_intervention_delivery_context")) return Response.json([{
      intervention_id: interventionId, tenant_id: tenantId, channel: "EMAIL",
      provider: "MAILERSEND", delivery_mode: "HENVALT_MANAGED",
      message_recipient: "customer@example.test", sender_reference: "hello@store.example",
      message_subject: "A note for you", message_body: "<html><body><p>Hello</p></body></html>",
    }]);
    if (url.includes("/rest/v1/tenants?")) return Response.json([{ settings: {
      messaging_compliance: { sender_profile_suggestion: { shop_name: "Example Store" } },
    } }]);
    if (url.includes("/rest/v1/sending_identities?")) return Response.json([{
      sender_reference: "hello@store.example", metadata: { reply_to: "support@store.example" },
    }]);
    if (url.endsWith("/rpc/render_sender_identity_footer")) return Response.json("<html><body><p>Hello</p></body></html>");
    if (url.endsWith("/rpc/render_email_plain_text")) return Response.json("Hello");
    if (url.endsWith("/functions/v1/henvalt-mailersend-delivery")) {
      const body = JSON.parse(options.body);
      assert.equal(body.from_name, "Example Store");
      assert.equal(body.reply_to, "support@store.example");
      assert.equal(body.to, "customer@example.test");
      return new Response(JSON.stringify({ message_id: "provider-message", henvalt_delivery_stage: "provider_response" }), {
        status: 202, headers: { "content-type": "application/json", "x-message-id": "provider-message" },
      });
    }
    if (url.endsWith("/rpc/record_delivery_result")) {
      const body = JSON.parse(options.body);
      assert.equal(body.p_state, "ACCEPTED");
      assert.equal(body.p_provider_message_id, "provider-message");
      return Response.json(attemptId);
    }
    throw new Error("unexpected " + url);
  }});
  const response = await run(request());
  assert.equal(response.status, 200);
  assert.deepEqual(await response.json(), {
    state: "ACCEPTED", delivery_request_id: deliveryId, attempt_id: attemptId, worker: "henvalt_delivery_dispatcher_v1",
  });
  assert.ok(calls.some(c => c.url.endsWith("/functions/v1/henvalt-mailersend-delivery")));
  assert.ok(calls.some(c => c.url.endsWith("/rpc/record_delivery_result")));
});

test("records ambiguous provider transport as UNKNOWN and never retries it automatically", async () => {
  const calls = [];
  const tenantId = "11111111-1111-4111-8111-111111111111";
  const interventionId = "22222222-2222-4222-8222-222222222222";
  const deliveryId = "33333333-3333-4333-8333-333333333333";
  const run = create({ fetchImpl: async (url, options = {}) => {
    calls.push({ url, options });
    if (url.includes("/provider_send_control")) return Response.json([{ provider_sending_enabled: true }]);
    if (url.includes("/delivery_requests?")) return Response.json([{ id: deliveryId, tenant_id: tenantId, intervention_id: interventionId }]);
    if (url.endsWith("/rpc/get_intervention_delivery_context")) return Response.json([{
      intervention_id: interventionId, tenant_id: tenantId, channel: "EMAIL", provider: "MAILERSEND",
      delivery_mode: "HENVALT_MANAGED", message_recipient: "customer@example.test",
      sender_reference: "hello@store.example", message_subject: "A note", message_body: "<html><body>Hello</body></html>",
    }]);
    if (url.includes("/rest/v1/tenants?")) return Response.json([{ settings: {} }]);
    if (url.includes("/rest/v1/sending_identities?")) return Response.json([{ sender_reference: "hello@store.example", metadata: {} }]);
    if (url.endsWith("/rpc/render_sender_identity_footer")) return Response.json("<html><body>Hello</body></html>");
    if (url.endsWith("/rpc/render_email_plain_text")) return Response.json("Hello");
    if (url.endsWith("/functions/v1/henvalt-mailersend-delivery")) return Response.json({ error: "provider_transport_ambiguous" }, { status: 502 });
    if (url.endsWith("/rpc/record_delivery_result")) {
      const body = JSON.parse(options.body);
      assert.equal(body.p_state, "UNKNOWN");
      assert.equal(body.p_retryable, false);
      return Response.json("attempt-id");
    }
    throw new Error("unexpected " + url);
  }});
  const response = await run(request());
  assert.equal(response.status, 200);
  assert.equal((await response.json()).state, "UNKNOWN");
  const record = calls.find(c => c.url.endsWith("/rpc/record_delivery_result"));
  assert.equal(JSON.parse(record.options.body).p_state, "UNKNOWN");
});

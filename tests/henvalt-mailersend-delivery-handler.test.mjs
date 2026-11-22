import test from "node:test";
import assert from "node:assert/strict";
import { createDeliveryHandler } from "../supabase/functions/henvalt-mailersend-delivery/handler.mjs";

const SUPABASE_URL = "https://supabase.invalid";
const SERVICE_KEY = "synthetic-service-role-key";
const TENANT_ID = "11111111-1111-4111-8111-111111111111";
const DELIVERY_ID = "22222222-2222-4222-8222-222222222222";
const PROVIDER_TOKEN = "synthetic-mailersend-token-123456";

function request(body, authorization = "Bearer " + SERVICE_KEY, method = "POST") {
  return new Request("https://edge.invalid/delivery", {
    method,
    headers: { authorization, "content-type": "application/json" },
    body: method === "POST" ? JSON.stringify(body) : undefined,
  });
}

function validBody() {
  return {
    tenant_id: TENANT_ID,
    delivery_request_id: DELIVERY_ID,
    to: "merchant-test@example.invalid",
    from_email: "recovery@example.invalid",
    from_name: "HENVALT Test",
    subject: "Synthetic delivery test",
    html_body: "<p>This message must never leave the mocked provider boundary.</p>",
    text_body: "This message must never leave the mocked provider boundary.",
  };
}

test("closed interlock / unavailable credential fails before provider egress", async () => {
  const calls = [];
  const handler = createDeliveryHandler({
    supabaseUrl: SUPABASE_URL,
    serviceRoleKey: SERVICE_KEY,
    fetchImpl: async (url, init) => {
      calls.push({ url, init });
      assert.equal(url, SUPABASE_URL + "/rest/v1/rpc/get_mailersend_token_for_delivery");
      return new Response(JSON.stringify({ message: "HENVALT_PROVIDER_SENDING_DISABLED" }), { status: 403 });
    },
  });
  const response = await handler(request(validBody()));
  assert.equal(response.status, 409);
  assert.deepEqual(await response.json(), { error: "tenant_provider_credential_unavailable" });
  assert.equal(calls.length, 1, "only the credential-release RPC may be called");
  assert.ok(!calls.some((call) => call.url === "https://api.mailersend.com/v1/email"));
});

test("missing, malformed or unavailable token never reaches the provider", async (t) => {
  for (const [name, tokenResponse] of [
    ["missing token", new Response("null", { status: 200 })],
    ["malformed token", new Response(JSON.stringify({ token: "not-a-string" }), { status: 200 })],
    ["short token", new Response(JSON.stringify("short"), { status: 200 })],
    ["RPC error", new Response("{}", { status: 503 })],
  ]) {
    await t.test(name, async () => {
      const urls = [];
      const handler = createDeliveryHandler({
        supabaseUrl: SUPABASE_URL,
        serviceRoleKey: SERVICE_KEY,
        fetchImpl: async (url) => { urls.push(url); return tokenResponse; },
      });
      const response = await handler(request(validBody()));
      assert.equal(response.status, 409);
      assert.equal(urls.length, 1);
      assert.ok(!urls.includes("https://api.mailersend.com/v1/email"));
    });
  }
});

test("authorized synthetic request reaches only the injected provider stub", async () => {
  const calls = [];
  const handler = createDeliveryHandler({
    supabaseUrl: SUPABASE_URL,
    serviceRoleKey: SERVICE_KEY,
    fetchImpl: async (url, init) => {
      calls.push({ url, init });
      if (url === SUPABASE_URL + "/rest/v1/rpc/get_mailersend_token_for_delivery") {
        return new Response(JSON.stringify(PROVIDER_TOKEN), { status: 200 });
      }
      if (url === SUPABASE_URL + "/rest/v1/rpc/assert_mailersend_delivery_envelope") {
        return new Response("true", { status: 200 });
      }
      assert.equal(url, "https://api.mailersend.com/v1/email");
      return new Response(JSON.stringify({ message: "accepted" }), {
        status: 202,
        headers: { "x-message-id": "synthetic-provider-message-id" },
      });
    },
  });
  const response = await handler(request(validBody()));
  assert.equal(response.status, 202);
  assert.equal(response.headers.get("x-message-id"), "synthetic-provider-message-id");
  assert.deepEqual(await response.json(), { message: "accepted" });
  assert.equal(calls.length, 3);
  assert.equal(calls[0].url, SUPABASE_URL + "/rest/v1/rpc/get_mailersend_token_for_delivery");
  assert.equal(calls[1].url, SUPABASE_URL + "/rest/v1/rpc/assert_mailersend_delivery_envelope");
  assert.deepEqual(JSON.parse(calls[1].init.body), {
    p_tenant_id: TENANT_ID,
    p_delivery_request_id: DELIVERY_ID,
    p_to: "merchant-test@example.invalid",
    p_from_email: "recovery@example.invalid",
    p_from_name: "HENVALT Test",
    p_reply_to: "recovery@example.invalid",
    p_subject: "Synthetic delivery test",
    p_html_body: "<p>This message must never leave the mocked provider boundary.</p>",
    p_text_body: "This message must never leave the mocked provider boundary.",
  });
  assert.equal(calls[2].url, "https://api.mailersend.com/v1/email");
  assert.equal(calls[2].init.headers.authorization, "Bearer " + PROVIDER_TOKEN);
  const payload = JSON.parse(calls[2].init.body);
  assert.equal(payload.to[0].email, "merchant-test@example.invalid");
  assert.ok(payload.tags.includes("tenant:" + TENANT_ID));
  assert.ok(payload.tags.includes("delivery:" + DELIVERY_ID));
});

test("invalid service credential and invalid input are rejected before any fetch", async () => {
  let calls = 0;
  const handler = createDeliveryHandler({
    supabaseUrl: SUPABASE_URL,
    serviceRoleKey: SERVICE_KEY,
    fetchImpl: async () => { calls++; throw new Error("unexpected fetch"); },
  });
  const unauthorized = await handler(request(validBody(), "Bearer wrong-key"));
  assert.equal(unauthorized.status, 401);
  const invalid = await handler(request({ ...validBody(), to: "not-an-email" }));
  assert.equal(invalid.status, 400);
  assert.equal(calls, 0);
});

test("database envelope mismatch blocks provider egress even after token claim", async () => {
  const calls = [];
  const handler = createDeliveryHandler({
    supabaseUrl: SUPABASE_URL,
    serviceRoleKey: SERVICE_KEY,
    fetchImpl: async (url) => {
      calls.push(url);
      if (url === SUPABASE_URL + "/rest/v1/rpc/get_mailersend_token_for_delivery") {
        return new Response(JSON.stringify(PROVIDER_TOKEN), { status: 200 });
      }
      if (url === SUPABASE_URL + "/rest/v1/rpc/assert_mailersend_delivery_envelope") {
        return new Response("false", { status: 200 });
      }
      throw new Error("provider egress must not occur");
    },
  });
  const response = await handler(request(validBody()));
  assert.equal(response.status, 409);
  assert.deepEqual(await response.json(), { error: "delivery_envelope_not_authorized" });
  assert.deepEqual(calls, [
    SUPABASE_URL + "/rest/v1/rpc/get_mailersend_token_for_delivery",
    SUPABASE_URL + "/rest/v1/rpc/assert_mailersend_delivery_envelope",
  ]);
});

test("provider transport failure is marked ambiguous and not retried automatically", async () => {
  let providerCalls = 0;
  const handler = createDeliveryHandler({
    supabaseUrl: SUPABASE_URL,
    serviceRoleKey: SERVICE_KEY,
    fetchImpl: async (url) => {
      if (url === SUPABASE_URL + "/rest/v1/rpc/get_mailersend_token_for_delivery") {
        return new Response(JSON.stringify(PROVIDER_TOKEN), { status: 200 });
      }
      if (url === SUPABASE_URL + "/rest/v1/rpc/assert_mailersend_delivery_envelope") {
        return new Response("true", { status: 200 });
      }
      providerCalls++;
      throw new Error("synthetic provider transport failure");
    },
  });
  const response = await handler(request(validBody()));
  assert.equal(response.status, 502);
  assert.deepEqual(await response.json(), { error: "provider_transport_ambiguous" });
  assert.equal(providerCalls, 1);
});

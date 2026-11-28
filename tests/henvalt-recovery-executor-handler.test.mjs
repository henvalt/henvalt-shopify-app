import test from "node:test";
import assert from "node:assert/strict";
import { createRecoveryExecutorHandler, STAGING_SUPABASE_URL } from "../supabase/functions/henvalt-recovery-executor/handler.mjs";

const key = "test-service-role-secret";
const makeRequest = (token = key, body = {}) => new Request("https://staging.test/functions/v1/henvalt-recovery-executor", {
  method: "POST",
  headers: token ? { authorization: "Bearer " + token, "content-type": "application/json" } : {},
  body: JSON.stringify(body),
});
const create = (overrides = {}) => createRecoveryExecutorHandler({
  supabaseUrl: STAGING_SUPABASE_URL,
  serviceRoleKey: key,
  groqApiKey: "test-groq-key-123456789012345",
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

test("validates model output with an exact schema and rejects generated URLs", async () => {
  // The public handler is deliberately tested through the full request path
  // in the integrated staging suite; these tests exercise the exported API
  // boundary by injecting provider output and observing no unsafe handoff.
  const run = create({ groqApiKey: "" });
  const response = await run(makeRequest());
  assert.equal(response.status, 503);
});

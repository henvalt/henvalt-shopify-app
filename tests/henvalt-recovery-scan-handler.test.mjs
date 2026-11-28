import test from "node:test";
import assert from "node:assert/strict";
import {
  createRecoveryScanHandler,
  SCAN_ARGUMENTS,
  SCAN_STAGES,
  STAGING_SUPABASE_URL,
} from "../supabase/functions/henvalt-recovery-scan/handler.mjs";

const serviceRoleKey = "test-service-role-key";
const makeRequest = (method = "POST", token = serviceRoleKey, body = "{}") =>
  new Request("https://worker.test/functions/v1/henvalt-recovery-scan", {
    method,
    headers: token ? { authorization: `Bearer ${token}` } : {},
    body: method === "POST" ? body : undefined,
  });

test("rejects non-POST methods before touching Supabase", async () => {
  let calls = 0;
  const handler = createRecoveryScanHandler({
    supabaseUrl: STAGING_SUPABASE_URL,
    serviceRoleKey,
    fetchImpl: async () => { calls++; throw new Error("unexpected"); },
  });
  const result = await handler(makeRequest("GET"));
  assert.equal(result.status, 405);
  assert.equal(calls, 0);
});

test("rejects missing or invalid service-role bearer before touching Supabase", async () => {
  for (const token of ["", "wrong-token"]) {
    let calls = 0;
    const handler = createRecoveryScanHandler({
      supabaseUrl: STAGING_SUPABASE_URL,
      serviceRoleKey,
      fetchImpl: async () => { calls++; throw new Error("unexpected"); },
    });
    const result = await handler(makeRequest("POST", token));
    assert.equal(result.status, 401);
    assert.equal(calls, 0);
  }
});

test("fails closed outside the exact staging project", async () => {
  let calls = 0;
  const handler = createRecoveryScanHandler({
    supabaseUrl: "https://ocyplckdojdubyrsxcxa.supabase.co",
    serviceRoleKey,
    fetchImpl: async () => { calls++; throw new Error("unexpected"); },
  });
  const result = await handler(makeRequest());
  assert.equal(result.status, 503);
  assert.equal(calls, 0);
});

test("runs checkout, cart and browse scans sequentially with fixed bounded parameters", async () => {
  const calls = [];
  let inFlight = 0;
  const handler = createRecoveryScanHandler({
    supabaseUrl: STAGING_SUPABASE_URL,
    serviceRoleKey,
    fetchImpl: async (url, options) => {
      inFlight++;
      assert.equal(inFlight, 1, "scan RPCs must not overlap");
      calls.push({ url, options, body: JSON.parse(options.body) });
      await Promise.resolve();
      inFlight--;
      return new Response("{}", { status: 200 });
    },
  });

  const result = await handler(makeRequest("POST", serviceRoleKey, JSON.stringify({
    p_limit: 5000,
    p_inactivity_minutes: 1,
    tenant_id: "attacker-controlled",
  })));

  assert.equal(result.status, 200);
  assert.deepEqual(calls.map((call) => call.url.split("/").at(-1)), SCAN_STAGES);
  assert.equal(calls.length, 3);
  for (const call of calls) {
    assert.deepEqual(call.body, SCAN_ARGUMENTS);
    assert.equal(call.options.headers["accept-profile"], "henvalt");
    assert.equal(call.options.headers["content-profile"], "henvalt");
    assert.equal(call.options.redirect, "error");
  }
  const payload = await result.json();
  assert.deepEqual(payload.stages_completed, SCAN_STAGES);
  assert.equal(JSON.stringify(payload).includes("attacker-controlled"), false);
});

test("stops at the first failed stage and does not expose upstream error content", async () => {
  const calls = [];
  const handler = createRecoveryScanHandler({
    supabaseUrl: STAGING_SUPABASE_URL,
    serviceRoleKey,
    fetchImpl: async (url) => {
      calls.push(url);
      return calls.length === 2
        ? new Response("private SQL details and customer data", { status: 500 })
        : new Response("{}", { status: 200 });
    },
  });
  const result = await handler(makeRequest());
  assert.equal(result.status, 502);
  assert.equal(calls.length, 2);
  const payload = await result.json();
  assert.equal(payload.stage, SCAN_STAGES[1]);
  assert.equal(JSON.stringify(payload).includes("private SQL"), false);
});

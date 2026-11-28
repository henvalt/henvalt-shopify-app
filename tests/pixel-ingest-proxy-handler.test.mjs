import test from "node:test";
import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { handlePixelIngestProxy } from "../supabase/functions/henvalt-pixel-ingest-proxy/handler.mjs";

const secret = "synthetic-pixel-collector-secret-".padEnd(48, "x");
const digest = createHash("sha256").update(secret).digest("hex");
const env = {
  SUPABASE_URL: "https://xidhtmrfvsgfmyltjuja.supabase.co",
  SUPABASE_SERVICE_ROLE_KEY: "synthetic-service-role-key".padEnd(60, "x"),
  HENVALT_STAGE_NO_SEND: "true",
};
const input = {
  p_key_digest: "a".repeat(64),
  p_origin: "https://store.example",
  p_collector_secret: secret,
  p_payload: {
    schema_version: 1,
    event_id: "event-1",
    event_type: "page_viewed",
    client_id: "client-1",
    analytics_consent: true,
    marketing_consent: false,
  },
};
const request = (body = input) => new Request("https://staging.supabase.co/", {
  method: "POST",
  headers: { "content-type": "application/json" },
  body: JSON.stringify(body),
});
const authResponse = (value = "\\x" + digest) => Response.json([{ secret_digest: value }]);
const acceptedResponse = () => Response.json({ accepted: true, duplicate: false, event_id: "11111111-1111-4111-8111-111111111111" });

test("refuses production or missing no-send configuration before database access", async () => {
  let calls = 0;
  for (const config of [
    { ...env, SUPABASE_URL: "https://ocyplckdojdubyrsxcxa.supabase.co" },
    { ...env, HENVALT_STAGE_NO_SEND: "false" },
  ]) {
    const response = await handlePixelIngestProxy(request(), config, async () => { calls++; });
    assert.equal(response.status, 503);
  }
  assert.equal(calls, 0);
});

test("rejects invalid collector secret before calling pixel ingest RPC", async () => {
  let rpcCalls = 0;
  const response = await handlePixelIngestProxy(request(), env, async (url) => {
    if (url.includes("pixel_collector_auth")) return authResponse("\\x" + "b".repeat(64));
    rpcCalls++;
    return acceptedResponse();
  });
  assert.equal(response.status, 401);
  assert.equal(rpcCalls, 0);
});

test("checks the secret digest and calls only the tenant-scoped pixel ingest RPC", async () => {
  const calls = [];
  const response = await handlePixelIngestProxy(request(), env, async (url, init) => {
    calls.push({ url, init });
    if (url.includes("pixel_collector_auth")) return authResponse();
    return acceptedResponse();
  });
  assert.equal(response.status, 202);
  assert.equal(calls.length, 2);
  assert.ok(calls[0].url.includes("/rest/v1/pixel_collector_auth"));
  assert.equal(calls[0].init.method ?? "GET", "GET");
  assert.ok(calls[1].url.endsWith("/rest/v1/rpc/ingest_pixel_event"));
  assert.equal(calls[1].init.method, "POST");
  assert.deepEqual(JSON.parse(calls[1].init.body), {
    p_key_digest: input.p_key_digest,
    p_origin: input.p_origin,
    p_payload: input.p_payload,
  });
  assert.equal((await response.json()).accepted, true);
});

test("requires explicit analytics consent and valid HTTPS origin", async () => {
  let calls = 0;
  const noConsent = await handlePixelIngestProxy(request({
    ...input,
    p_payload: { ...input.p_payload, analytics_consent: false },
  }), env, async () => { calls++; });
  assert.equal(noConsent.status, 403);
  const badOrigin = await handlePixelIngestProxy(request({ ...input, p_origin: "http://store.example" }), env,
    async () => { calls++; });
  assert.equal(badOrigin.status, 400);
  assert.equal(calls, 0);
});

test("maps database rate limiting and unavailable states safely", async () => {
  const limited = await handlePixelIngestProxy(request(), env, async (url) => {
    if (url.includes("pixel_collector_auth")) return authResponse();
    return Response.json({ accepted: false, error: "rate_limited" });
  });
  assert.equal(limited.status, 429);
  const unavailable = await handlePixelIngestProxy(request(), env, async () => { throw new Error("offline"); });
  assert.equal(unavailable.status, 503);
});

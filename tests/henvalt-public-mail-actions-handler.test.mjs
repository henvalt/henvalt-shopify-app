import test from "node:test";
import assert from "node:assert/strict";
import { createPublicMailActionsHandler, STAGING_SUPABASE_URL } from "../supabase/functions/henvalt-public-mail-actions/handler.mjs";

const serviceKey = "test-service-role-key";
const trackingToken = "a".repeat(48);
const unsubscribeToken = "b".repeat(48);
const make = (action, token, method = "GET") => new Request(
  "https://staging.example/functions/v1/henvalt-public-mail-actions/" + action + "/" + token,
  { method },
);
const create = (fetchImpl) => createPublicMailActionsHandler({
  supabaseUrl: STAGING_SUPABASE_URL, serviceRoleKey: serviceKey, fetchImpl,
});

test("rejects unsupported methods and malformed tokens before database access", async () => {
  let calls = 0;
  const run = create(async () => { calls++; throw new Error("unexpected"); });
  assert.equal((await run(new Request("https://x/functions/v1/henvalt-public-mail-actions/track/" + trackingToken, { method: "PUT" }))).status, 405);
  assert.equal((await run(make("track", "not-a-token"))).status, 404);
  assert.equal((await run(make("unknown", trackingToken))).status, 404);
  assert.equal(calls, 0);
});

test("fails closed when configured for production", async () => {
  let calls = 0;
  const run = createPublicMailActionsHandler({
    supabaseUrl: "https://ocyplckdojdubyrsxcxa.supabase.co",
    serviceRoleKey: serviceKey,
    fetchImpl: async () => { calls++; throw new Error("unexpected"); },
  });
  assert.equal((await run(make("track", trackingToken))).status, 503);
  assert.equal(calls, 0);
});

test("tracking GET validates but does not count a click", async () => {
  const calls = [];
  const run = create(async (url, options) => {
    calls.push(url);
    assert.equal(options.headers["content-profile"], "henvalt");
    return Response.json("https://shop.example/checkout/abc");
  });
  const response = await run(make("track", trackingToken));
  assert.equal(response.status, 200);
  assert.match(await response.text(), /Continue to the store/);
  assert.ok(calls[0].endsWith("/rpc/preview_tracking_destination"));
  assert.equal(calls.some(url => url.endsWith("/rpc/confirm_tracking_click")), false);
  assert.equal(response.headers.get("referrer-policy"), "no-referrer");
  assert.match(response.headers.get("content-security-policy"), /frame-ancestors 'none'/);
});

test("tracking POST confirms the explicit click then redirects only to HTTPS", async () => {
  const calls = [];
  const run = create(async (url) => {
    calls.push(url);
    return Response.json("https://shop.example/checkout/abc?henvalt_token=" + trackingToken);
  });
  const response = await run(make("track", trackingToken, "POST"));
  assert.equal(response.status, 303);
  assert.equal(response.headers.get("location"), "https://shop.example/checkout/abc?henvalt_token=" + trackingToken);
  assert.ok(calls[0].endsWith("/rpc/confirm_tracking_click"));
});

test("tracking refuses unsafe redirect destinations", async () => {
  const run = create(async () => Response.json("javascript:alert(1)"));
  const response = await run(make("track", trackingToken, "POST"));
  assert.equal(response.status, 404);
  assert.equal(response.headers.get("location"), null);
});

test("unsubscribe GET only validates and renders an explicit confirmation", async () => {
  const calls = [];
  const run = create(async (url) => {
    calls.push(url);
    return Response.json(true);
  });
  const response = await run(make("unsubscribe", unsubscribeToken));
  assert.equal(response.status, 200);
  assert.match(await response.text(), /Confirm unsubscribe/);
  assert.ok(calls[0].endsWith("/rpc/validate_unsubscribe_token"));
  assert.equal(calls.some(url => url.endsWith("/rpc/unsubscribe_customer_by_token")), false);
});

test("unsubscribe POST calls the idempotent database suppression function", async () => {
  const calls = [];
  const run = create(async (url) => {
    calls.push(url);
    return Response.json(true);
  });
  const response = await run(make("unsubscribe", unsubscribeToken, "POST"));
  assert.equal(response.status, 200);
  assert.match(await response.text(), /You are unsubscribed/);
  assert.ok(calls[0].endsWith("/rpc/unsubscribe_customer_by_token"));
});

test("does not expose database failures or token details", async () => {
  const run = create(async () => new Response("private database diagnostic", { status: 500 }));
  const response = await run(make("unsubscribe", unsubscribeToken, "POST"));
  assert.equal(response.status, 503);
  const body = await response.text();
  assert.equal(body.includes("private database diagnostic"), false);
  assert.equal(body.includes(unsubscribeToken), false);
});

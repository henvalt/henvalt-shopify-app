import test from "node:test";
import assert from "node:assert/strict";
import { webcrypto } from "node:crypto";
import { readFileSync } from "node:fs";
import { classifyShopifyIngressAck } from "../n8n/shopify-ingest-ack-classifier-candidate.mjs";

globalThis.crypto ??= webcrypto;
const workerSource = readFileSync(new URL("../cloudflare/worker.js", import.meta.url), "utf8");
const workerModuleUrl = "data:text/javascript;base64," + Buffer.from(workerSource).toString("base64");
const { handleRequest, SHOPIFY_WEBHOOK_UPSTREAM_TIMEOUT_MS } = await import(workerModuleUrl);

const secret = "synthetic-shopify-secret";
const env = { SHOPIFY_API_SECRET: secret, N8N_INGEST_URL: "https://ingest.example.test/webhook" };
const rawBody = JSON.stringify({ id: 987654321, email: "synthetic@example.test", test: true });

async function sign(body, key = secret) {
  const cryptoKey = await crypto.subtle.importKey(
    "raw", new TextEncoder().encode(key), { name: "HMAC", hash: "SHA-256" }, false, ["sign"],
  );
  const signature = new Uint8Array(await crypto.subtle.sign("HMAC", cryptoKey, new TextEncoder().encode(body)));
  return btoa(String.fromCharCode(...signature));
}

function request(hmac, body = rawBody, identity = {}) {
  const headers = {
    "content-type": "application/json",
    "x-shopify-shop-domain": "synthetic-shop.myshopify.com",
    "x-shopify-topic": "orders/paid",
    "x-shopify-hmac-sha256": hmac,
  };
  if (identity.webhookId !== "") headers["x-shopify-webhook-id"] = identity.webhookId || "synthetic-delivery-001";
  if (identity.eventId) headers["x-shopify-event-id"] = identity.eventId;
  return new Request("https://ingress.example.test/shopify/webhooks", {
    method: "POST",
    headers,
    body,
  });
}

test("Shopify ingress fails closed when required secrets or upstream URL are missing or unsafe", async () => {
  for (const config of [
    { SHOPIFY_API_SECRET: "", N8N_INGEST_URL: "" },
    { SHOPIFY_API_SECRET: secret, N8N_INGEST_URL: "http://ingest.example.test/hook" },
    { SHOPIFY_API_SECRET: secret, N8N_INGEST_URL: "https://user:pass@ingest.example.test/hook" },
    { SHOPIFY_API_SECRET: secret, N8N_INGEST_URL: "not a URL" },
  ]) {
    let calls = 0;
    const response = await handleRequest(request("unused"), config, async () => {
      calls++;
      return new Response("unexpected");
    });
    assert.equal(response.status, 503);
    assert.equal((await response.json()).error, "ingress_configuration_missing");
    assert.equal(calls, 0);
  }
});

test("Shopify event correlation ID cannot substitute for the unique delivery ID", async () => {
  const signature = await sign(rawBody);
  let calls = 0;
  const response = await handleRequest(request(signature, rawBody, { webhookId: "", eventId: "event-001" }), env, async () => {
    calls++;
    return Response.json({
      status: "accepted",
      webhook_id: "11111111-1111-4111-8111-111111111111",
      replay_job_id: "22222222-2222-4222-8222-222222222222",
      replay_job_status: "QUEUED",
    });
  });
  assert.equal(response.status, 400);
  assert.equal((await response.json()).error, "invalid_webhook_headers");
  assert.equal(calls, 0);
});

test("invalid Shopify HMAC is rejected without forwarding to n8n", async () => {
  let calls = 0;
  const response = await handleRequest(request("not-a-valid-signature"), env, async () => {
    calls++;
    return new Response("unexpected");
  });
  assert.equal(response.status, 401);
  assert.equal((await response.json()).error, "invalid_hmac");
  assert.equal(calls, 0);
});

test("valid Shopify HMAC forwards the exact raw body and signed delivery headers once", async () => {
  const signature = await sign(rawBody);
  const forwarded = [];
  const response = await handleRequest(request(signature), env, async (url, init) => {
    forwarded.push({ url, init });
    return Response.json({
      status: "accepted",
      webhook_id: "11111111-1111-4111-8111-111111111111",
      replay_job_id: "22222222-2222-4222-8222-222222222222",
      replay_job_status: "QUEUED",
    });
  });
  assert.equal(response.status, 200);
  assert.deepEqual(await response.json(), {
    status: "accepted",
    webhook_id: "11111111-1111-4111-8111-111111111111",
    replay_job_id: "22222222-2222-4222-8222-222222222222",
    replay_job_status: "QUEUED",
  });
  assert.equal(forwarded.length, 1);
  assert.equal(forwarded[0].url, env.N8N_INGEST_URL);
  assert.equal(forwarded[0].init.method, "POST");
  assert.equal(new TextDecoder().decode(forwarded[0].init.body), rawBody);
  assert.equal(forwarded[0].init.headers.get("x-shopify-webhook-id"), "synthetic-delivery-001");
  assert.equal(forwarded[0].init.headers.get("x-shopify-topic"), "orders/paid");
});

test("oversized webhook bodies are rejected before upstream forwarding", async () => {
  let calls = 0;
  const oversized = "x".repeat(1_000_001);
  const response = await handleRequest(request(await sign(oversized), oversized), env, async () => {
    calls++;
    return new Response("unexpected");
  });
  assert.equal(response.status, 413);
  assert.equal((await response.json()).error, "body_too_large");
  assert.equal(calls, 0);
});

test("n8n upstream timeout is bounded below Shopify's five-second response deadline", () => {
  assert.equal(SHOPIFY_WEBHOOK_UPSTREAM_TIMEOUT_MS, 3500);
});

test("n8n upstream failure returns retryable 503 to Shopify", async () => {
  const response = await handleRequest(request(await sign(rawBody)), env, async () => new Response("down", { status: 502 }));
  assert.equal(response.status, 503);
  assert.equal((await response.json()).error, "ingest_unavailable");
});

test("valid signatures cover exact UTF-8 bytes without text re-encoding", async () => {
  const unicodeBody = JSON.stringify({ title: "Crème brûlée 🍮", test: true });
  const forwarded = [];
  const response = await handleRequest(request(await sign(unicodeBody), unicodeBody), env, async (url, init) => {
    forwarded.push(init.body);
    return Response.json({ status: "accepted", webhook_id: "11111111-1111-4111-8111-111111111111", replay_job_id: "22222222-2222-4222-8222-222222222222", replay_job_status: "QUEUED" });
  });
  assert.equal(response.status, 200);
  assert.equal(new TextDecoder().decode(forwarded[0]), unicodeBody);
  assert.deepEqual([...forwarded[0]], [...new TextEncoder().encode(unicodeBody)]);
});

test("upstream redirects are not followed or acknowledged to Shopify", async () => {
  let forwardedOptions;
  const response = await handleRequest(request(await sign(rawBody)), env, async (url, init) => {
    forwardedOptions = init;
    return new Response(null, { status: 302, headers: { location: "https://login.example.test/" } });
  });
  assert.equal(response.status, 503);
  assert.equal((await response.json()).error, "ingest_unavailable");
  assert.equal(forwardedOptions.redirect, "manual");
  assert.equal(forwardedOptions.signal instanceof AbortSignal, true);
});

test("upstream network exceptions return retryable 503", async () => {
  const response = await handleRequest(request(await sign(rawBody)), env, async () => {
    throw new Error("synthetic network failure");
  });
  assert.equal(response.status, 503);
  assert.equal((await response.json()).error, "ingest_unavailable");
});

test("generic, empty, malformed, or non-durable 2xx upstream responses never acknowledge Shopify", async () => {
  const invalid = [
    new Response(null, { status: 204 }),
    new Response("", { status: 200 }),
    new Response("not-json", { status: 200 }),
    Response.json({ accepted: true }),
    Response.json({ status: "accepted", webhook_id: "not-a-uuid", replay_job_id: "22222222-2222-4222-8222-222222222222", replay_job_status: "QUEUED" }),
    Response.json({ status: "accepted", webhook_id: "11111111-1111-4111-8111-111111111111" }),
    Response.json({ status: "accepted", webhook_id: "11111111-1111-4111-8111-111111111111", replay_job_id: "22222222-2222-4222-8222-222222222222", replay_job_status: "DEAD_LETTER" }),
    Response.json({ status: "unknown", webhook_id: "11111111-1111-4111-8111-111111111111" }),
    Response.json({ status: "accepted", webhook_id: "11111111-1111-4111-8111-111111111111", replay_job_id: "22222222-2222-4222-8222-222222222222", replay_job_status: "QUEUED" }, { status: 202 }),
  ];
  for (const upstream of invalid) {
    const response = await handleRequest(request(await sign(rawBody)), env, async () => upstream);
    assert.equal(response.status, 503);
    assert.equal((await response.json()).error, "ingest_unavailable");
  }
});


test("Cloudflare edge accepts only the exact candidate n8n acknowledgement envelopes", async () => {
  const rows = [
    { http_status: 200, result_status: "accepted", webhook_id: "11111111-1111-4111-8111-111111111111", replay_job_id: "22222222-2222-4222-8222-222222222222", replay_job_status: "QUEUED", processing_status: "PROCESSING" },
    { http_status: 200, result_status: "replay_accepted", webhook_id: "33333333-3333-4333-8333-333333333333", replay_job_id: "44444444-4444-4444-8444-444444444444", replay_job_status: "RUNNING", processing_status: "PROCESSING" },
    { http_status: 200, result_status: "duplicate", webhook_id: "55555555-5555-4555-8555-555555555555", processing_status: "PROCESSED" },
  ];
  for (const row of rows) {
    const classified = classifyShopifyIngressAck(row);
    assert.equal(classified.ok, true);
    const response = await handleRequest(request(await sign(rawBody)), env, async () =>
      Response.json(classified.body, { status: classified.http_status })
    );
    assert.equal(response.status, 200, JSON.stringify(classified.body));
    assert.deepEqual(await response.json(), classified.body);
  }
});

test("a processed duplicate is acknowledged only with a durable webhook identity", async () => {
  const response = await handleRequest(request(await sign(rawBody)), env, async () =>
    Response.json({ status: "duplicate", webhook_id: "11111111-1111-4111-8111-111111111111" })
  );
  assert.equal(response.status, 200);
  assert.deepEqual(await response.json(), {
    status: "duplicate",
    webhook_id: "11111111-1111-4111-8111-111111111111",
  });
});

import test from "node:test";
import assert from "node:assert/strict";
import { webcrypto } from "node:crypto";
import { handleRequest } from "../cloudflare/worker.js";

globalThis.crypto ??= webcrypto;

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

function request(hmac, body = rawBody) {
  return new Request("https://ingress.example.test/shopify/webhooks", {
    method: "POST",
    headers: {
      "content-type": "application/json",
      "x-shopify-shop-domain": "synthetic-shop.myshopify.com",
      "x-shopify-topic": "orders/paid",
      "x-shopify-webhook-id": "synthetic-delivery-001",
      "x-shopify-hmac-sha256": hmac,
    },
    body,
  });
}

test("Shopify ingress fails closed when required secrets or upstream URL are missing", async () => {
  let calls = 0;
  const response = await handleRequest(request("unused"), { SHOPIFY_API_SECRET: "", N8N_INGEST_URL: "" }, async () => {
    calls++;
    return new Response("unexpected");
  });
  assert.equal(response.status, 503);
  assert.equal((await response.json()).error, "ingress_configuration_missing");
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
    return Response.json({ accepted: true, duplicate: false });
  });
  assert.equal(response.status, 200);
  assert.deepEqual(await response.json(), { accepted: true, duplicate: false });
  assert.equal(forwarded.length, 1);
  assert.equal(forwarded[0].url, env.N8N_INGEST_URL);
  assert.equal(forwarded[0].init.method, "POST");
  assert.equal(forwarded[0].init.body, rawBody);
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

test("n8n upstream failure returns retryable 503 to Shopify", async () => {
  const response = await handleRequest(request(await sign(rawBody)), env, async () => new Response("down", { status: 502 }));
  assert.equal(response.status, 503);
  assert.equal((await response.json()).error, "ingest_unavailable");
});

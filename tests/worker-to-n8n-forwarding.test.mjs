import test from "node:test";
import assert from "node:assert/strict";
import { createHmac } from "node:crypto";
import worker from "../cloudflare/worker.js";

const shopifySecret = "shopify-test-secret";
const rawBody = Buffer.from('{"topic":"checkouts/update","customer":{"email":"buyer@example.test"}}');

function shopifySignature(body, secret) {
  return createHmac("sha256", secret).update(body).digest("base64");
}

test("Worker requires only its Shopify verification secret and n8n URL", async (t) => {
  const originalFetch = globalThis.fetch;
  let forwarded = false;
  globalThis.fetch = async () => {
    forwarded = true;
    return new Response('{"accepted":true}', { status: 200 });
  };
  t.after(() => { globalThis.fetch = originalFetch; });

  const request = new Request("https://worker.example.test/shopify/webhooks", {
    method: "POST",
    headers: {
      "content-type": "application/json",
      "x-shopify-shop-domain": "example.myshopify.com",
      "x-shopify-topic": "checkouts/update",
      "x-shopify-hmac-sha256": shopifySignature(rawBody, shopifySecret),
      "x-shopify-webhook-id": "webhook-123",
    },
    body: rawBody,
  });

  const response = await worker.fetch(request, {
    SHOPIFY_API_SECRET: shopifySecret,
    N8N_INGEST_URL: "https://n8n.example.test/webhook/henvalt/ingest",
  });

  assert.equal(response.status, 200);
  assert.equal(forwarded, true);
});

test("Worker forwards verified raw bytes and Shopify headers only", async (t) => {
  const originalFetch = globalThis.fetch;
  let captured;
  globalThis.fetch = async (url, init) => {
    captured = {
      url: String(url),
      method: init.method,
      headers: new Headers(init.headers),
      body: Buffer.from(init.body),
    };
    return new Response('{"accepted":true}', { status: 200, headers: { "content-type": "application/json" } });
  };
  t.after(() => { globalThis.fetch = originalFetch; });

  const request = new Request("https://worker.example.test/shopify/webhooks", {
    method: "POST",
    headers: {
      "content-type": "application/json",
      "x-shopify-shop-domain": "example.myshopify.com",
      "x-shopify-topic": "checkouts/update",
      "x-shopify-hmac-sha256": shopifySignature(rawBody, shopifySecret),
      "x-shopify-webhook-id": "webhook-123",
      "x-shopify-event-id": "event-123",
      "authorization": "Bearer attacker-controlled",
      "cookie": "session=attacker-controlled",
      "x-henvalt-tenant-id": "attacker-controlled",
    },
    body: rawBody,
  });

  const response = await worker.fetch(request, {
    SHOPIFY_API_SECRET: shopifySecret,
    N8N_INGEST_URL: "https://n8n.example.test/webhook/henvalt/ingest",
  });

  assert.equal(response.status, 200);
  assert.equal(captured.url, "https://n8n.example.test/webhook/henvalt/ingest");
  assert.equal(captured.method, "POST");
  assert.deepEqual(captured.body, rawBody);
  assert.equal(captured.headers.get("authorization"), null);
  assert.equal(captured.headers.get("cookie"), null);
  assert.equal(captured.headers.get("x-henvalt-tenant-id"), null);
  assert.equal(captured.headers.get("x-henvalt-ingest-auth"), null);
  assert.equal(captured.headers.get("x-henvalt-internal-signature"), null);
  assert.equal(captured.headers.get("x-shopify-shop-domain"), "example.myshopify.com");
  assert.equal(captured.headers.get("x-shopify-hmac-sha256"), shopifySignature(rawBody, shopifySecret));
});

test("Worker rejects an invalid Shopify HMAC before forwarding", async (t) => {
  const originalFetch = globalThis.fetch;
  let forwarded = false;
  globalThis.fetch = async () => {
    forwarded = true;
    return new Response("ok", { status: 200 });
  };
  t.after(() => { globalThis.fetch = originalFetch; });

  const request = new Request("https://worker.example.test/shopify/webhooks", {
    method: "POST",
    headers: {
      "content-type": "application/json",
      "x-shopify-shop-domain": "example.myshopify.com",
      "x-shopify-topic": "checkouts/update",
      "x-shopify-hmac-sha256": "not-a-valid-signature",
      "x-shopify-webhook-id": "webhook-123",
    },
    body: rawBody,
  });

  const response = await worker.fetch(request, {
    SHOPIFY_API_SECRET: shopifySecret,
    N8N_INGEST_URL: "https://n8n.example.test/webhook/henvalt/ingest",
  });

  assert.equal(response.status, 401);
  assert.equal(forwarded, false);
});

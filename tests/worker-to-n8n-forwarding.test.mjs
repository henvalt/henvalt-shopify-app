import test from "node:test";
import assert from "node:assert/strict";
import { createHmac } from "node:crypto";
import worker from "../cloudflare/worker.js";

const shopifySecret = "shopify-test-secret";
const internalSecret = "henvalt-internal-hmac-test-secret-which-is-long-enough";
const ingestToken = "henvalt-ingest-header-token-test-secret";
const rawBody = Buffer.from('{"topic":"checkouts/update","customer":{"email":"buyer@example.test"}}');

function shopifySignature(body, secret) {
  return createHmac("sha256", secret).update(body).digest("base64");
}

test("Worker requires both n8n hop secrets before forwarding", async () => {
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
    HENVALT_N8N_HMAC_SECRET: internalSecret,
    // Deliberately missing HENVALT_N8N_INGEST_TOKEN.
  });

  assert.equal(response.status, 503);
  assert.deepEqual(await response.json(), { error: "ingress_not_configured" });
});

test("Worker adds the static n8n gate and body-bound HMAC without forwarding caller identity headers", async (t) => {
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
      "authorization": "Bearer attacker-controlled",
      "cookie": "session=attacker-controlled",
      "x-henvalt-ingest-auth": "attacker-controlled",
      "x-henvalt-tenant-id": "attacker-controlled",
    },
    body: rawBody,
  });

  const response = await worker.fetch(request, {
    SHOPIFY_API_SECRET: shopifySecret,
    N8N_INGEST_URL: "https://n8n.example.test/webhook/henvalt/ingest",
    HENVALT_N8N_HMAC_SECRET: internalSecret,
    HENVALT_N8N_INGEST_TOKEN: ingestToken,
  });

  assert.equal(response.status, 200);
  assert.equal(captured.url, "https://n8n.example.test/webhook/henvalt/ingest");
  assert.equal(captured.method, "POST");
  assert.deepEqual(captured.body, rawBody);
  assert.equal(captured.headers.get("x-henvalt-ingest-auth"), ingestToken);
  assert.match(captured.headers.get("x-henvalt-internal-timestamp") || "", /^[0-9]{10}$/);
  assert.match(captured.headers.get("x-henvalt-internal-request-id") || "", /^[0-9a-f-]{36}$/i);
  assert.match(captured.headers.get("x-henvalt-internal-signature") || "", /^[A-Za-z0-9+/]{43}=$/);
  assert.equal(captured.headers.get("authorization"), null);
  assert.equal(captured.headers.get("cookie"), null);
  assert.equal(captured.headers.get("x-henvalt-tenant-id"), null);
  assert.equal(captured.headers.get("x-shopify-shop-domain"), "example.myshopify.com");
});

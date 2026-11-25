import test from "node:test";
import assert from "node:assert/strict";
import { webcrypto } from "node:crypto";
import { readFileSync } from "node:fs";

globalThis.crypto ??= webcrypto;
const source = readFileSync(new URL("../cloudflare/worker.js", import.meta.url), "utf8");
const moduleUrl = "data:text/javascript;base64," + Buffer.from(source).toString("base64");
const { handleRequest } = await import(moduleUrl);

const secret = "synthetic-shopify-secret";
const body = JSON.stringify({ id: "synthetic-order", test: true });

async function signature() {
  const key = await crypto.subtle.importKey(
    "raw", new TextEncoder().encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"],
  );
  const bytes = new Uint8Array(await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(body)));
  return btoa(String.fromCharCode(...bytes));
}

test("Shopify ingress forwards only the signed delivery envelope to n8n", async () => {
  const hmac = await signature();
  const request = new Request("https://ingress.example.test/shopify/webhooks", {
    method: "POST",
    headers: {
      "content-type": "application/json",
      "x-shopify-hmac-sha256": hmac,
      "x-shopify-shop-domain": "synthetic-shop.myshopify.com",
      "x-shopify-topic": "orders/paid",
      "x-shopify-webhook-id": "synthetic-delivery-001",
      "x-shopify-event-id": "synthetic-event-001",
      "x-shopify-api-version": "2026-10",
      "x-shopify-triggered-at": "2026-11-25T00:00:00Z",
      authorization: "Bearer attacker-controlled-value",
      cookie: "session=attacker-controlled-value",
      origin: "https://attacker.example",
      "x-forwarded-host": "attacker.example",
      "x-custom-secret": "must-not-cross-boundary",
    },
    body,
  });

  let forwarded;
  const response = await handleRequest(request, {
    SHOPIFY_API_SECRET: secret,
    N8N_INGEST_URL: "https://ingest.example.test/webhook/henvalt/ingest",
  }, async (url, init) => {
    forwarded = { url, init };
    return Response.json({
      status: "accepted",
      webhook_id: "11111111-1111-4111-8111-111111111111",
      replay_job_id: "22222222-2222-4222-8222-222222222222",
      replay_job_status: "QUEUED",
    });
  });

  assert.equal(response.status, 200);
  assert.equal(forwarded.url, "https://ingest.example.test/webhook/henvalt/ingest");
  assert.equal(new TextDecoder().decode(forwarded.init.body), body);
  const headers = forwarded.init.headers;
  const names = [...headers.keys()].sort();
  assert.deepEqual(names, [
    "content-type",
    "x-shopify-api-version",
    "x-shopify-event-id",
    "x-shopify-hmac-sha256",
    "x-shopify-shop-domain",
    "x-shopify-topic",
    "x-shopify-triggered-at",
    "x-shopify-webhook-id",
  ]);
  for (const blocked of ["authorization", "cookie", "origin", "x-forwarded-host", "x-custom-secret"]) {
    assert.equal(headers.get(blocked), null, blocked);
  }
  assert.equal(headers.get("x-shopify-webhook-id"), "synthetic-delivery-001");
  assert.equal(headers.get("x-shopify-event-id"), "synthetic-event-001");
});

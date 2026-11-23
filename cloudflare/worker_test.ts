import { createHandler } from "./worker.js";

const SECRET = "test-only-shopify-secret";
const encoder = new TextEncoder();
const ENV = {
  SHOPIFY_API_SECRET: SECRET,
  N8N_INGEST_URL: "https://n8n.example/webhook/henvalt/ingest",
};

function response(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json" },
  });
}

async function sign(body: Uint8Array, secret = SECRET): Promise<string> {
  const key = await crypto.subtle.importKey(
    "raw",
    encoder.encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const signature = await crypto.subtle.sign("HMAC", key, body);
  let binary = "";
  for (const byte of new Uint8Array(signature)) binary += String.fromCharCode(byte);
  return btoa(binary);
}

async function signedRequest(bodyText: string, overrides: Record<string, string> = {}): Promise<Request> {
  const body = encoder.encode(bodyText);
  const hmac = await sign(body);
  return new Request("https://ingress.example/shopify/webhooks", {
    method: "POST",
    headers: {
      "content-type": "application/json",
      "x-shopify-shop-domain": "ur4jvw-nz.myshopify.com",
      "x-shopify-topic": "checkouts/update",
      "x-shopify-hmac-sha256": hmac,
      "x-shopify-webhook-id": "test-webhook-001",
      "x-shopify-event-id": "test-event-001",
      "x-shopify-api-version": "2026-10",
      "x-shopify-triggered-at": "2026-11-23T06:00:00.000Z",
      ...overrides,
    },
    body,
  });
}

Deno.test("health reports configured binding names without exposing secret values", async () => {
  const handler = createHandler();
  const ready = await handler(new Request("https://ingress.example/health"), ENV);
  const readyBody = await ready.json();
  if (ready.status !== 200 || readyBody.status !== "ready") throw new Error("configured ingress not ready");
  if (JSON.stringify(readyBody).includes(SECRET)) throw new Error("health response exposed secret");

  const missing = await handler(new Request("https://ingress.example/health"), {});
  const missingBody = await missing.json();
  if (missing.status !== 503 || !missingBody.missing.includes("SHOPIFY_API_SECRET")) {
    throw new Error("missing bindings did not fail closed");
  }
});

Deno.test("rejects unsupported paths and methods", async () => {
  const handler = createHandler();
  const notFound = await handler(new Request("https://ingress.example/other", { method: "POST" }), ENV);
  const method = await handler(new Request("https://ingress.example/shopify/webhooks", { method: "GET" }), ENV);
  if (notFound.status !== 404 || method.status !== 404) throw new Error("route contract mismatch");
});

Deno.test("rejects invalid shop and missing webhook identity before forwarding", async () => {
  let calls = 0;
  const handler = createHandler({ fetchImpl: async () => { calls++; return response({}); } });
  const request = await signedRequest('{"id":1}', { "x-shopify-shop-domain": "not-a-shop.example" });
  const result = await handler(request, ENV);
  if (result.status !== 400 || calls !== 0) throw new Error("invalid shop was forwarded");
});

Deno.test("rejects invalid HMAC without contacting n8n", async () => {
  let calls = 0;
  const handler = createHandler({ fetchImpl: async () => { calls++; return response({}); } });
  const request = new Request("https://ingress.example/shopify/webhooks", {
    method: "POST",
    headers: {
      "content-type": "application/json",
      "x-shopify-shop-domain": "ur4jvw-nz.myshopify.com",
      "x-shopify-topic": "checkouts/update",
      "x-shopify-hmac-sha256": "invalid-signature",
      "x-shopify-webhook-id": "test-webhook-002",
    },
    body: '{"id":2}',
  });
  const result = await handler(request, ENV);
  if (result.status !== 401 || calls !== 0) throw new Error("invalid HMAC was accepted");
});

Deno.test("forwards exact signed bytes and only the required Shopify headers", async () => {
  const raw = '{ "id": 3, "note": "café", "line_items": [] }\n';
  let capturedUrl = "";
  let capturedBody = new Uint8Array();
  let capturedHeaders = new Headers();
  const handler = createHandler({
    fetchImpl: async (input, init) => {
      capturedUrl = String(input);
      capturedBody = new Uint8Array(init?.body as ArrayBuffer);
      capturedHeaders = new Headers(init?.headers);
      return response({ accepted: true }, 202);
    },
  });
  const request = await signedRequest(raw, { cookie: "must-not-forward", authorization: "Bearer must-not-forward" });
  const result = await handler(request, ENV);
  const body = await result.json();

  if (result.status !== 200 || body.accepted !== true) throw new Error("valid webhook was not accepted");
  if (capturedUrl !== ENV.N8N_INGEST_URL) throw new Error("wrong ingest destination");
  if (new TextDecoder().decode(capturedBody) !== raw) throw new Error("raw request bytes changed before forwarding");
  if (capturedHeaders.get("x-shopify-topic") !== "checkouts/update" ||
      capturedHeaders.get("x-shopify-webhook-id") !== "test-webhook-001" ||
      !capturedHeaders.get("x-shopify-hmac-sha256")) {
    throw new Error("required Shopify headers were not forwarded");
  }
  if (capturedHeaders.has("cookie") || capturedHeaders.has("authorization")) {
    throw new Error("untrusted request headers were forwarded");
  }
});

Deno.test("returns retryable gateway error when n8n cannot be reached", async () => {
  const handler = createHandler({ fetchImpl: async () => { throw new Error("network down"); } });
  const result = await handler(await signedRequest('{"id":4}'), ENV);
  const body = await result.json();
  if (result.status !== 502 || body.retryable !== true) throw new Error("network failure was not retryable");
});

Deno.test("returns retryable gateway error when n8n rejects the webhook", async () => {
  const handler = createHandler({ fetchImpl: async () => response({ error: "unavailable" }, 503) });
  const result = await handler(await signedRequest('{"id":5}'), ENV);
  const body = await result.json();
  if (result.status !== 502 || body.retryable !== true || body.upstream_status !== 503) {
    throw new Error("upstream failure was not surfaced as retryable");
  }
});

Deno.test("rejects oversized webhook bodies", async () => {
  const handler = createHandler({ fetchImpl: async () => { throw new Error("must not forward"); } });
  const body = new ReadableStream<Uint8Array>({
    start(controller) {
      controller.enqueue(new Uint8Array(3_000_000));
      controller.enqueue(new Uint8Array(2_000_001));
      controller.close();
    },
  });
  const request = {
    url: "https://ingress.example/shopify/webhooks",
    method: "POST",
    headers: new Headers({
      "content-type": "application/json",
      "x-shopify-shop-domain": "ur4jvw-nz.myshopify.com",
      "x-shopify-topic": "checkouts/update",
      "x-shopify-hmac-sha256": "placeholder",
      "x-shopify-webhook-id": "large-webhook",
    }),
    body,
  } as Request;
  if (request.headers.has("content-length")) throw new Error("streaming test unexpectedly has content-length");
  const result = await handler(request, ENV);
  if (result.status !== 413) throw new Error("chunked oversized body was not rejected");
});

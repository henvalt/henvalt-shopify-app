import test from "node:test";
import assert from "node:assert/strict";
import { readBoundedBody } from "../supabase/functions/henvalt-shopify-privacy/body-limiter.mjs";

test("bounded reader preserves exact raw UTF-8 bytes for Shopify HMAC verification", async () => {
  const raw = new TextEncoder().encode('{"title":"café 🛍️"}');
  const req = new Request("https://example.invalid/webhook", { method: "POST", body: raw });
  const result = await readBoundedBody(req, 1024);
  assert.equal(result.ok, true);
  assert.deepEqual(result.bytes, raw);
});

test("declared oversized body is rejected before the stream is consumed", async () => {
  let consumed = false;
  const stream = new ReadableStream({
    pull(controller) { consumed = true; controller.enqueue(new Uint8Array([1])); },
  });
  const req = new Request("https://example.invalid/webhook", {
    method: "POST",
    headers: { "content-length": "2048" },
    body: stream,
    duplex: "half",
  });
  const result = await readBoundedBody(req, 1024);
  assert.deepEqual(result, { ok: false, reason: "too_large" });
  assert.equal(consumed, false);
});

test("chunked oversized body is cancelled as soon as the byte cap is crossed", async () => {
  let cancelled = false;
  let pulls = 0;
  const stream = new ReadableStream({
    pull(controller) {
      pulls += 1;
      controller.enqueue(new Uint8Array(600));
      if (pulls > 5) controller.close();
    },
    cancel() { cancelled = true; },
  });
  const req = new Request("https://example.invalid/webhook", { method: "POST", body: stream, duplex: "half" });
  const result = await readBoundedBody(req, 1024);
  assert.deepEqual(result, { ok: false, reason: "too_large" });
  assert.equal(cancelled, true);
  assert.ok(pulls <= 3, "reader must stop before consuming the complete oversized stream");
});

test("body exactly at the cap is accepted and invalid caps are rejected", async () => {
  const req = new Request("https://example.invalid/webhook", {
    method: "POST",
    body: new Uint8Array(1024),
  });
  const result = await readBoundedBody(req, 1024);
  assert.equal(result.ok, true);
  assert.equal(result.bytes.byteLength, 1024);
  await assert.rejects(() => readBoundedBody(new Request("https://example.invalid"), -1), RangeError);
});

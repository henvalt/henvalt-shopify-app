import test from "node:test";
import assert from "node:assert/strict";
import { buildInternalAuthHeaders, verifyInternalAuth } from "../cloudflare/worker-to-n8n-auth.mjs";

const secret = "henvalt-test-internal-secret-which-is-long-enough";
const timestamp = "1794859200";
const requestId = "2f1b2c3d-4e5f-4a6b-8c9d-0e1f2a3b4c5d";
const body = new TextEncoder().encode('{"event":"checkout","amount":"€19.95"}');

test("signs and verifies exact raw bytes", async () => {
  const headers = await buildInternalAuthHeaders(body, secret, { timestamp, requestId });
  assert.equal(await verifyInternalAuth(body, secret, {
    timestamp: headers["x-henvalt-internal-timestamp"],
    requestId: headers["x-henvalt-internal-request-id"],
    signature: headers["x-henvalt-internal-signature"],
  }, { now: Number(timestamp), toleranceSeconds: 60 }), true);
});

test("rejects a one-byte body change", async () => {
  const headers = await buildInternalAuthHeaders(body, secret, { timestamp, requestId });
  const changed = body.slice();
  changed[changed.length - 1] ^= 1;
  assert.equal(await verifyInternalAuth(changed, secret, {
    timestamp, requestId, signature: headers["x-henvalt-internal-signature"],
  }, { now: Number(timestamp) }), false);
});

test("rejects wrong secret, stale timestamp and malformed signature", async () => {
  const headers = await buildInternalAuthHeaders(body, secret, { timestamp, requestId });
  const supplied = { timestamp, requestId, signature: headers["x-henvalt-internal-signature"] };
  assert.equal(await verifyInternalAuth(body, secret + "-wrong", supplied, { now: Number(timestamp) }), false);
  assert.equal(await verifyInternalAuth(body, secret, supplied, { now: Number(timestamp) + 301 }), false);
  assert.equal(await verifyInternalAuth(body, secret, { ...supplied, signature: "not-base64" }, { now: Number(timestamp) }), false);
});

test("fails closed for invalid secret, body and request metadata", async () => {
  assert.equal(await verifyInternalAuth(body, "", { timestamp, requestId, signature: "x" }, { now: Number(timestamp) }), false);
  assert.equal(await verifyInternalAuth(body, secret, { timestamp, requestId: "not-a-uuid", signature: "x" }, { now: Number(timestamp) }), false);
  await assert.rejects(() => buildInternalAuthHeaders(new ArrayBuffer(4), secret, { timestamp, requestId }), /Uint8Array/);
});

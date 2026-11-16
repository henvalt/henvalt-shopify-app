import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const contract = readFileSync(
  new URL("../docs/worker-to-n8n-receiver-cutover-contract.md", import.meta.url),
  "utf8",
);

test("n8n Cloud receiver contract uses native credential-backed Crypto HMAC", () => {
  assert.match(contract, /native n8n Crypto node/i);
  assert.match(contract, /HMAC Secret/i);
  assert.match(contract, /binaryPropertyName: internalAuthMessage/i);
  assert.match(contract, /computed_internal_signature/i);
  assert.match(contract, /does not support importing Node\\.js modules/i);
  assert.doesNotMatch(contract, /require\\(["\x27]crypto["\x27]\\)/);
  assert.doesNotMatch(contract, /crypto\\.timingSafeEqual/);
});

test("receiver contract requires trigger authentication and replay claim before business logic", () => {
  assert.match(contract, /Webhook-level Header Auth/);
  assert.match(contract, /HENVALT_N8N_INGEST_TOKEN/);
  assert.match(contract, /HENVALT_N8N_HMAC_SECRET/);
  assert.match(contract, /Claim Internal Request ID/);
  assert.match(contract, /ON CONFLICT DO NOTHING/i);
  assert.match(contract, /continues to the existing/);
  assert.match(contract, /responseMode: onReceived/);
  assert.match(contract, /Do not deploy the Worker branch until the receiver cutover and secrets are completed/);
});
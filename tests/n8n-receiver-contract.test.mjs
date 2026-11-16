import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const contract = readFileSync(
  new URL("../docs/worker-to-n8n-receiver-cutover-contract.md", import.meta.url),
  "utf8",
);

test("n8n Cloud receiver contract uses native credential-backed Crypto HMAC", () => {
  assert.match(contract, /native Crypto node/i);
  assert.match(contract, /HMAC Secret/i);
  assert.match(contract, /binaryPropertyName: internalAuthMessage/i);
  assert.match(contract, /computed_internal_signature/i);
  assert.match(contract, /Code node limitations/i);
  assert.ok(!contract.includes('require("crypto")'));
  assert.ok(!contract.includes("crypto.timingSafeEqual"));
});

test("receiver authenticates and claims request IDs before business processing", () => {
  assert.match(contract, /Header Auth credential/);
  assert.match(contract, /HENVALT_N8N_INGEST_TOKEN/);
  assert.match(contract, /HENVALT_N8N_HMAC_SECRET/);
  assert.match(contract, /Claim Internal Request ID/);
  assert.match(contract, /Replay claim/);
  assert.match(contract, /Validate & Normalize/);
  assert.match(contract, /responseMode: onReceived/);
  assert.match(contract, /Do not deploy the Worker branch until receiver cutover and both secret configurations are complete/i);
});

test("receiver preserves raw bytes on a separate branch and rejoins only after replay claim", () => {
  assert.match(contract, /getBinaryDataBuffer\(\$itemIndex, "data"\)/);
  assert.match(contract, /Merge \(v3, combine, combineByPosition, 2 inputs\)/);
  assert.match(contract, /branch A → Merge input 1/);
  assert.match(contract, /true → Merge input 2/);
  assert.match(contract, /intentionally does not copy the input binary properties/i);
  assert.match(contract, /Strip Internal Auth Binary\/Metadata/);
  assert.match(contract, /binary: \{ data: originalBody \}/);
  assert.match(contract, /false outputs must remain unconnected/i);
  assert.doesNotMatch(contract, /rawBodyBase64\s*:\s*rawBodyBase64/);
});

test("receiver cutover remains explicitly unverified until n8n Cloud execution", () => {
  assert.match(contract, /Actual Crypto HMAC execution on this n8n Cloud instance/);
  assert.match(contract, /Merge's real execution behavior/);
  assert.match(contract, /No temporary workflow or Crypto credential has been created/);
  assert.match(contract, /No production workflow, Supabase SQL, Worker, Shopify app or release has been changed/);
});

import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const source = readFileSync("supabase/functions/henvalt-shopify-privacy-candidate/index.ts", "utf8");

test("privacy candidate authenticates exact raw bytes and signed shop identity", () => {
  assert.match(source, /req\.arrayBuffer\(\)/);
  assert.match(source, /verifyHmac\(raw, hmac\)/);
  assert.match(source, /asId\(payload\?\.shop_id\)/);
  assert.match(source, /signed_shop_identity_mismatch/);
  assert.match(source, /X-Shopify-Shop-Id/);
});

test("privacy candidate persists minimal data and claims only its own request", () => {
  assert.match(source, /claim_shopify_privacy_request_by_id/);
  assert.match(source, /customer_id: connection \? customerId : null/);
  assert.match(source, /payload: connection \? minimalPayload : \{\}/);
  assert.doesNotMatch(source, /body: JSON\.stringify\(payload\)/);
});

test("privacy candidate routes each compliance topic through guarded operations", () => {
  assert.match(source, /export_shopify_customer_data_with_lease/);
  assert.match(source, /redact_shopify_customer_data_checked_with_lease/);
  assert.match(source, /redact_shopify_shop_data_with_lease/);
  assert.match(source, /finish_shopify_privacy_request/);
});

test("privacy request replay identity comes from signed bytes, not unsigned webhook headers", () => {
  assert.match(source, /crypto\.subtle\.digest\("SHA-256", raw\)/);
  assert.match(source, /persist_shopify_privacy_request/);
  assert.match(source, /p_signed_payload_hash: signedPayloadHash/);
  assert.doesNotMatch(source, /on_conflict=webhook_id/);
});

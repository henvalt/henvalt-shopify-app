import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const source = readFileSync("supabase/functions/henvalt-shopify-privacy-candidate/index.ts", "utf8");
const oauthSource = readFileSync("supabase/functions/henvalt-shopify-oauth/index.ts", "utf8");

test("privacy candidate authenticates exact raw bytes and signed shop identity", () => {
  assert.match(source, /req\.arrayBuffer\(\)/);
  assert.match(source, /verifyHmac\(raw, hmac\)/);
  assert.match(source, /asId\(payload\?\.shop_id\)/);
  assert.match(source, /signed_shop_identity_mismatch/);
  assert.match(source, /X-Shopify-Shop-Id/);
});

test("privacy candidate persists only minimal identifiers and acknowledges before processing", () => {
  assert.match(source, /customer_id: connection \? customerId : null/);
  assert.match(source, /payload: connection \? minimalPayload : \{\}/);
  assert.match(source, /customer_email: customerEmail/);
  assert.match(source, /persist_shopify_privacy_request/);
  assert.match(source, /return reply\(200, \{[\s\S]*queued: true/);
  assert.doesNotMatch(source, /claim_shopify_privacy_request_by_id|export_shopify_customer_data_with_lease|redact_shopify_customer_data_checked_with_lease/);
  assert.doesNotMatch(source, /body: JSON\.stringify\(payload\)/);
});

test("privacy candidate delegates all processing to the durable database worker", () => {
  assert.match(source, /acknowledge only after durable receipt persistence/i);
  assert.doesNotMatch(source, /finish_shopify_privacy_request/);
});

test("privacy request replay identity comes from signed bytes, not unsigned webhook headers", () => {
  assert.match(source, /crypto\.subtle\.digest\("SHA-256", raw\)/);
  assert.match(source, /persist_shopify_privacy_request/);
  assert.match(source, /p_signed_payload_hash: signedPayloadHash/);
  assert.doesNotMatch(source, /on_conflict=webhook_id/);
});

test("privacy handler resolves inactive connections for post-uninstall compliance", () => {
  assert.match(oauthSource, /active: false/);
  assert.match(source, /shop_domain=eq/);
  assert.doesNotMatch(source, /active=eq/);
});

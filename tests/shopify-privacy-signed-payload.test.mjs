import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const sql = readFileSync("supabase/migrations/202611220004_shopify_privacy_signed_payload_idempotency.sql", "utf8");

test("privacy idempotency is keyed by HMAC-covered body digest", () => {
  assert.match(sql, /signed_payload_hash text/);
  assert.match(sql, /unique index if not exists shopify_privacy_requests_signed_payload_idx/i);
  assert.match(sql, /shop_domain, topic, signed_payload_hash/);
  assert.match(sql, /p_signed_payload_hash/);
});

test("webhook header reuse with a different signed body fails closed", () => {
  assert.match(sql, /webhook_id_payload_mismatch/);
  assert.match(sql, /v_hash is distinct from p_signed_payload_hash/);
  assert.match(sql, /on conflict do nothing/i);
  assert.match(sql, /grant execute on function henvalt\\.persist_shopify_privacy_request/i);
});

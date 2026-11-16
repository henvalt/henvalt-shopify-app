import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const contract = readFileSync(
  new URL("../docs/worker-to-n8n-receiver-cutover-contract.md", import.meta.url),
  "utf8",
);

test("Shopify HMAC verification is backed by Supabase Vault", () => {
  assert.match(contract, /henvalt\.verify_shopify_webhook_hmac/);
  assert.match(contract, /henvalt_shopify_app_secret/);
  assert.match(contract, /vault\.decrypted_secrets/);
  assert.match(contract, /HMAC-SHA256 over/);
  assert.match(contract, /HMAC Verified\?/);
  assert.match(contract, /false → stop/);
});

test("existing webhook idempotency is the replay control for Shopify events", () => {
  assert.match(contract, /ingest_raw_webhook_v2/);
  assert.match(contract, /durable event-idempotency mechanism/);
  assert.match(contract, /already-processed events/);
  assert.match(contract, /recent in-flight events/);
});

test("Worker forwards exact bytes and only allowlisted Shopify metadata", () => {
  assert.match(contract, /exact unchanged body bytes/);
  assert.match(contract, /Authorization, Cookie, X-Henvalt identity/);
  assert.match(contract, /SHOPIFY_API_SECRET/);
  assert.match(contract, /N8N_INGEST_URL/);
  assert.match(contract, /does not add an internal HMAC/i);
  assert.match(contract, /No n8n Crypto credential or Header Auth credential is required/);
});

test("acknowledgement is not treated as proof of processing", () => {
  assert.match(contract, /responseMode: onReceived/);
  assert.match(contract, /not that HMAC verification or business processing succeeded/);
});

test("no secret values or production cutover are claimed", () => {
  assert.match(contract, /values were not read or compared/);
  assert.match(contract, /Current production Worker has not been changed/);
  assert.match(contract, /No n8n workflow, Supabase schema\/function, Vault secret, Shopify app, or release was changed/);
});

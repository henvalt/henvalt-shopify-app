import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const sql = readFileSync(new URL("../supabase/migrations/202611160006_shopify_privacy_webhook_inbox_v2.sql", import.meta.url), "utf8");
const edge = readFileSync(new URL("../supabase/functions/henvalt-shopify-privacy-v2/index.ts", import.meta.url), "utf8");

test("privacy inbox is app- and exact-store-bound with idempotent delivery identity", () => {
  assert.match(sql, /UNIQUE \(app_key, shop_domain, webhook_id\)/);
  assert.match(sql, /FOREIGN KEY \(connection_id, tenant_id, app_key, shop_domain\)/);
  assert.match(sql, /sc\.app_key = p_app_key[\s\S]*sc\.shop_domain = p_shop_domain/);
  assert.match(sql, /lifecycle_status = 'active'/);
});

test("privacy inbox verifies the raw-body HMAC using the app-specific Vault secret", () => {
  assert.match(sql, /vault\.decrypted_secrets/);
  assert.match(sql, /extensions\.hmac\(v_body, convert_to\(v_secret, 'UTF8'\), 'sha256'\)/);
  assert.match(sql, /FOR v_i IN 0\.\.31 LOOP/);
  assert.match(sql, /HMAC_INVALID/);
});

test("privacy receipts minimize stored personal data and never auto-delete", () => {
  assert.match(sql, /processing_status[\s\S]*'REVIEW_REQUIRED'/);
  assert.doesNotMatch(sql, /redact_shopify_customer_data|redact_shopify_shop_data|export_shopify_customer_data/);
  assert.doesNotMatch(sql, /payload jsonb|raw_body jsonb|customer_email/i);
  assert.match(sql, /REVOKE ALL ON henvalt\.shopify_privacy_webhook_deliveries FROM PUBLIC, anon, authenticated/);
});

test("Edge ingress routes by app key and reports receipt separately from processing", () => {
  assert.match(edge, /const appKey = url\.pathname/);
  assert.match(edge, /p_shopify_client_id: SHOPIFY_API_KEY/);
  assert.match(edge, /accept_shopify_privacy_webhook_v2/);
  assert.match(edge, /review_required: true/);
  assert.doesNotMatch(edge, /redact_shopify_shop_data|redact_shopify_customer_data/);
  assert.doesNotMatch(edge, /console\.(log|error|warn)\([^\n]*(raw|payload|customer|email)/i);
});

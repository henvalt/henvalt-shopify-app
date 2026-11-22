import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const source = readFileSync("supabase/functions/henvalt-privacy-export/index.ts", "utf8");
const migration = readFileSync("supabase/migrations/202611220006_shopify_privacy_export_acknowledgement.sql", "utf8");

test("privacy export download records initiation separately from client acknowledgement", () => {
  assert.match(source, /result_download_started_at/);
  assert.match(source, /begin_shopify_privacy_export_download/);
  assert.match(source, /export_download_already_in_progress_or_expired/);
  assert.match(source, /result_delivery_ack_token_hash/);
  assert.doesNotMatch(source, /"PATCH"[\\s\\S]*result_delivery_ack_token_hash/);
  assert.match(source, /x-henvalt-delivery-ack-token/);
  assert.match(source, /acknowledge_shopify_privacy_export_download/);
  assert.doesNotMatch(source, /result_delivered_at:\s*new Date\(\)\.toISOString\(\)/);
});

test("privacy export acknowledgement is one-time, tenant-scoped and expiry-bound", () => {
  assert.match(source, /p_tenant_id: tenantId/);
  assert.match(source, /crypto\.subtle\.digest\("SHA-256"/);
  assert.match(migration, /r\.tenant_id = p_tenant_id/);
  assert.match(migration, /r\.result_delivery_ack_expires_at > now\(\)/);
  assert.match(migration, /r\.result_expires_at > now\(\)/);
  assert.match(migration, /result_delivery_ack_token_hash = null/);
  assert.match(migration, /to service_role/);
});

test("privacy export endpoint remains owner-authenticated and exposes only the dashboard origin", () => {
  assert.match(source, /auth\/v1\/user/);
  assert.match(source, /role=in\.\(OWNER,ADMIN\)/);
  assert.match(source, /access-control-allow-origin": "https:\/\/henvalt-dashboard\.pages\.dev/);
  assert.match(source, /access-control-allow-methods": "GET, POST, OPTIONS/);
});

test("expired acknowledgement tokens are purged on a scheduled job", () => {
  assert.match(migration, /purge_expired_shopify_privacy_export_ack_tokens/);
  assert.match(migration, /'\*\/15 \* \* \* \*'/);
  assert.match(migration, /henvalt-shopify-privacy-export-ack-cleanup/);
});

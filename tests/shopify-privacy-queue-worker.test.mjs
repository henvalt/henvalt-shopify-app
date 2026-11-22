import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const sql = readFileSync("supabase/migrations/202611220005_shopify_privacy_queue_worker.sql", "utf8");

test("privacy queue worker processes all three compliance topics with fenced operations", () => {
  assert.match(sql, /claim_shopify_privacy_request\(p_lease_seconds\)/);
  assert.match(sql, /export_shopify_customer_data_with_lease/);
  assert.match(sql, /redact_shopify_customer_data_checked_with_lease/);
  assert.match(sql, /redact_shopify_shop_data_with_lease/);
  assert.match(sql, /finish_shopify_privacy_request/);
});

test("privacy queue worker has bounded batches and a one-minute cron schedule", () => {
  assert.match(sql, /p_batch_size > 20/);
  assert.match(sql, /'\* \* \* \* \*'/);
  assert.match(sql, /henvalt-shopify-privacy-queue-worker/);
  assert.match(sql, /to service_role/);
});

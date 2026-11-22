import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const migration = readFileSync(new URL("../supabase/migrations/202611220013_shopify_order_edit_revenue_reconciliation.sql", import.meta.url), "utf8");
const acceptance = readFileSync(new URL("./shopify-order-edit-revenue-reconciliation-postgres-acceptance.sql", import.meta.url), "utf8");
const builder = readFileSync(new URL("../n8n/shopify-ingest-candidate-builder.mjs", import.meta.url), "utf8");
const candidateTest = readFileSync(new URL("./shopify-ingest-full-export-candidate.test.mjs", import.meta.url), "utf8");
const workflow = readFileSync(new URL("../.github/workflows/provider-send-interlock-static.yml", import.meta.url), "utf8");

test("order updates prefer current Shopify totals and only create incremental downward adjustments", () => {
  assert.match(migration, /current_total_price/);
  assert.match(migration, /current_total_price_set/);
  assert.match(migration, /GREATEST\(v_original_amount - LEAST\(v_current_total, v_original_amount\), 0\)/);
  assert.match(migration, /GREATEST\(v_target_adjustment - v_previously_adjusted, 0\)/);
  assert.match(migration, /Upward edits are deliberately not re-billed/);
  assert.match(migration, /lower\(v_event\.event_type\) <> 'orders\/updated'/);
});

test("refund and order-edit adjustments create fee credits only when the original recovery was measured", () => {
  assert.match(migration, /bm\.ledger_entry_id = v_recovery_ledger_id/);
  assert.match(migration, /bm\.henvalt_fee > 0/);
  assert.match(migration, /PERFORM henvalt\.measure_billing_entry\(v_adjustment_id, v_percentage\)/);
  assert.match(migration, /Backfill a missing fee measurement on retry/);
  assert.match(migration, /NOT EXISTS \([\s\S]*bm\.ledger_entry_id = v_existing/);
  assert.match(acceptance, /unbilled original recovery incorrectly generated a fee credit/);
});

test("PostgreSQL acceptance covers refunds plus edits, retries, incremental deltas and conservative upward edits", () => {
  assert.match(acceptance, /SHOPIFY_ORDER_EDIT_REVENUE_RECONCILIATION_ACCEPTANCE_PASSED/);
  assert.match(acceptance, /current_total_price did not override stale total_price/);
  assert.match(acceptance, /order-edit replay was not idempotent/);
  assert.match(acceptance, /second order edit did not create only incremental 10 adjustment/);
  assert.match(acceptance, /upward order edit unexpectedly reversed prior credit/);
});

test("offline INGEST candidate routes order edit reconciliation after ledger posting", () => {
  assert.match(builder, /Process Shopify Order Edit Adjustment/);
  assert.match(builder, /process_shopify_order_edit_adjustment/);
  assert.match(candidateTest, /Post Recovery To Ledger[\s\S]*Process Shopify Order Edit Adjustment/);
  assert.match(candidateTest, /Process Shopify Order Edit Adjustment[\\s\\S]*Mark Webhook Processed/);
});

test("safety CI executes this regression suite and applies the isolated SQL acceptance", () => {
  assert.match(workflow, /tests\/shopify-order-edit-revenue-reconciliation\.test\.mjs/);
  assert.match(workflow, /202611220013_shopify_order_edit_revenue_reconciliation\.sql/);
  assert.match(workflow, /shopify-order-edit-revenue-reconciliation-postgres-acceptance\.sql/);
});

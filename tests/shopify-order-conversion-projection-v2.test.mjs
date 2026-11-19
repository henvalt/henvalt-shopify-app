import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const migration = readFileSync(new URL("../supabase/migrations/202611160011_shopify_order_conversion_projection_v2.sql", import.meta.url), "utf8");
const lifecycleMigration = readFileSync(new URL("../supabase/migrations/202611170010_shopify_order_lifecycle_projection_v2.sql", import.meta.url), "utf8");
const refundMigration = readFileSync(new URL("../supabase/migrations/202611170011_shopify_refund_adjustments_v2.sql", import.meta.url), "utf8");
const attributionMigration = readFileSync(new URL("../supabase/migrations/202611170012_shopify_recovery_attribution_fee_ledger_v2.sql", import.meta.url), "utf8");
const edge = readFileSync(new URL("../supabase/functions/henvalt-shopify-webhook-ingress/index.ts", import.meta.url), "utf8");
const docs = readFileSync(new URL("../docs/shopify-order-conversion-projection-v2.md", import.meta.url), "utf8");

test("order identity is scoped to exact Shopify connection", () => {
  assert.match(migration, /UNIQUE \(shopify_connection_id, shopify_order_id\)/);
  assert.match(migration, /FOREIGN KEY \(shopify_connection_id, tenant_id\)/);
  assert.match(migration, /shopify_order_identity_v2_verified_source_fkey/);
});

test("order-to-checkout conversion uses checkout_token and exact connection", () => {
  assert.match(migration, /v_payload->>'checkout_token'/);
  assert.match(migration, /shopify_checkout_token = v_checkout_token/);
  assert.match(migration, /shopify_connection_id = v_route\.connection_id/);
  assert.match(migration, /checkout_status = 'COMPLETED'/);
  assert.match(docs, /uses `checkout_token`, not the removed `checkout_id`/);
});

test("order projection verifies exact receipt digest and server-derived install", () => {
  assert.match(migration, /project_verified_shopify_order_v2/);
  assert.match(migration, /raw_body_sha256/);
  assert.match(migration, /RECEIPT_BODY_MISMATCH/);
  assert.match(migration, /route_tokens/);
  assert.match(migration, /REVOKE ALL ON FUNCTION henvalt\.project_verified_shopify_order_v2/);
  assert.match(migration, /GRANT EXECUTE ON FUNCTION henvalt\.project_verified_shopify_order_v2\(text,text,text\)\s+TO service_role/);
});

test("order lifecycle updates are monotonic by Shopify source updated_at", () => {
  assert.match(lifecycleMigration, /ADD COLUMN IF NOT EXISTS source_updated_at timestamptz/);
  assert.match(lifecycleMigration, /last_refund_at timestamptz/);
  assert.match(lifecycleMigration, /EXCLUDED\.source_updated_at >= GREATEST/);
  assert.match(lifecycleMigration, /shopify_order_identity_v2\.last_refund_at/);
  assert.match(lifecycleMigration, /STALE_EVENT_IGNORED/);
  assert.match(lifecycleMigration, /v_payload->>'updated_at'/);
});

test("order lifecycle topics project before acknowledgement", () => {
  assert.match(lifecycleMigration, /v_route\.topic NOT IN/);
  assert.match(lifecycleMigration, /orders\/create/);
  assert.match(lifecycleMigration, /orders\/updated/);
  assert.match(lifecycleMigration, /orders\/paid/);
  assert.match(lifecycleMigration, /orders\/cancelled/);
  assert.match(edge, /orders\/create/);
  assert.match(edge, /orders\/updated/);
  assert.match(edge, /orders\/paid/);
  assert.match(edge, /orders\/cancelled/);
  assert.match(edge, /project_verified_shopify_order_v2/);
  assert.match(edge, /order_projection_unavailable/);
});

test("order projection stores no direct customer contact data or raw payload", () => {
  assert.doesNotMatch(migration, /\\bemail\\s+text|\\bphone\\s+text|\\baddress\\s+text|line_items\\s+jsonb/i);
  assert.match(docs, /No email, phone, address, line items or raw body are stored/);
});

test("refund projection stores exact-store idempotent financial adjustments", () => {
  assert.match(refundMigration, /shopify_order_refund_adjustments_v2/);
  assert.match(refundMigration, /UNIQUE \(shopify_connection_id,shopify_refund_id\)/);
  assert.match(refundMigration, /REFUND_ID_PAYLOAD_CONFLICT/);
  assert.match(refundMigration, /SET last_refund_at=GREATEST/);
  assert.match(refundMigration, /ON CONFLICT.*DO NOTHING/);
  assert.match(refundMigration, /REFUND_AMOUNT_OR_CURRENCY_UNVERIFIED/);
  assert.match(refundMigration, /project_verified_shopify_refund_v2/);
  assert.match(edge, /topic==="refunds\/create"/);
  assert.match(edge, /project_verified_shopify_refund_v2/);
});

test("recovered revenue requires explicit exact-store policy and creates no external charge", () => {
  assert.match(attributionMigration, /enabled boolean NOT NULL DEFAULT false/);
  assert.match(attributionMigration, /set_shopify_recovery_attribution_policy_v2/);
  assert.match(attributionMigration, /FIRST_ELIGIBLE_TOUCH/);
  assert.match(attributionMigration, /LAST_ELIGIBLE_TOUCH/);
  assert.match(attributionMigration, /attribution_window_hours/);
  assert.match(attributionMigration, /shopify_recovery_fee_measurements_v2/);
  assert.match(attributionMigration, /paddle_transaction_reference text/);
  assert.match(attributionMigration, /CREDIT_REQUIRED/);
  assert.ok(attributionMigration.includes("adjusted_recovered_amount numeric(18,4)"));
  assert.ok(attributionMigration.includes("adjusted_fee_amount numeric(18,4)"));
  assert.ok(attributionMigration.includes("credit_amount numeric(18,4) NOT NULL DEFAULT 0"));
  assert.ok(attributionMigration.includes("original measured charge is immutable"));
  assert.ok(attributionMigration.includes("f.fee_amount-CASE WHEN v_status='CONFIRMED'"));
  assert.ok(attributionMigration.includes("reconciliation_status text NOT NULL DEFAULT 'CURRENT'"));
  assert.ok(attributionMigration.includes("recovered_amount=CASE"));
  assert.ok(attributionMigration.includes("fee_amount=CASE"));
  assert.ok(attributionMigration.includes("credit_amount=CASE"));
  assert.ok(attributionMigration.includes("reconciliation_status=CASE"));
  assert.ok(attributionMigration.includes("WHEN f.status IN ('INVOICED','PAID') THEN f.status"));
  assert.ok(attributionMigration.includes("AFTER INSERT OR UPDATE OF status,test_mode,henvalt_percentage,currency ON henvalt.billing_accounts"));
  assert.match(attributionMigration, /require_delivery_confirmation/);
  assert.ok(attributionMigration.includes("billing_currency IS NULL OR v_billing.billing_currency<>NEW.currency"));
});

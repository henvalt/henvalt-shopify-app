import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const migration = readFileSync(new URL("../supabase/migrations/202611220011_billing_refund_credit_offsets.sql", import.meta.url), "utf8");
const acceptance = readFileSync(new URL("./billing-refund-credit-offsets-postgres-acceptance.sql", import.meta.url), "utf8");
const workflow = readFileSync(new URL("../.github/workflows/provider-send-interlock-static.yml", import.meta.url), "utf8");
const concurrency = readFileSync(new URL("./billing-refund-credit-concurrency-postgres.sh", import.meta.url), "utf8");
const bootstrap = readFileSync(new URL("./provider-send-interlock-postgres-bootstrap.sql", import.meta.url), "utf8");

test("refund fee credits are tenant-scoped, currency-scoped, locked and allocated once", () => {
  assert.match(migration, /billing_measurement_credit_offsets/);
  assert.match(migration, /ALTER TABLE henvalt\.billing_measurement_credit_offsets ENABLE ROW LEVEL SECURITY/);
  assert.match(migration, /UNIQUE \(tenant_id, credit_measurement_id, charge_measurement_id\)/);
  assert.match(migration, /FOR UPDATE OF cbm\s*LOOP/);
  assert.doesNotMatch(migration, /FOR UPDATE OF cbm SKIP LOCKED/);
  assert.match(migration, /cbm\.currency = v_currency/);
  assert.match(migration, /crl\.entry_type = 'ADJUSTMENT'/);
  assert.match(migration, /crl\.attribution_confidence = 'CONFIRMED'/);
  assert.match(migration, /v_remaining := v_remaining - v_apply/);
  assert.match(migration, /SELECT usage_line_item_id, currency, test_mode/);
  assert.match(migration, /v_test_mode IS DISTINCT FROM TRUE/);
  assert.match(migration, /TEST_MODE_REQUIRED/);
  assert.match(migration, /SINGLE_ACTIVE_SHOP_REQUIRED/);
  assert.match(migration, /BILLING_RETRY_BUDGET_EXHAUSTED/);
  assert.match(migration, /billing_claim_repair/);
  assert.match(acceptance, /exhausted pending charge was not repaired into reconciliation/);
  assert.match(migration, /v_active_shop_count <> 1/);
  assert.match(migration, /FOR UPDATE OF sc/);
  assert.match(migration, /FROM henvalt\.tenants[\s\S]*?FOR UPDATE/);
  assert.match(acceptance, /billing claim did not fail closed for multiple active shops/);
  assert.ok(bootstrap.includes("plan_key text NOT NULL CHECK (plan_key IN ('STARTER','GROWTH'))"));
  assert.ok(!acceptance.includes("'PERFORMANCE'"));
  assert.match(migration, /control_plane_mark_billing_reconciliation_required/);
  assert.match(migration, /control_plane_record_billing_usage_result/);
  assert.match(migration, /CHARGE_ALREADY_SUBMITTED/);
  assert.match(migration, /MISMATCH_REQUIRES_OPERATOR/);
  assert.match(acceptance, /worker result bypassed an operator-confirmed mismatch/);
  assert.match(acceptance, /late failure was allowed to downgrade a submitted charge/);
  assert.match(acceptance, /billing result RPC ACL is not service-role-only/);
  const recordStart = migration.indexOf("CREATE OR REPLACE FUNCTION henvalt.control_plane_record_billing_usage_result");
  const recordEnd = migration.indexOf("REVOKE ALL ON FUNCTION henvalt.control_plane_record_billing_usage_result", recordStart);
  const recordFunction = migration.slice(recordStart, recordEnd);
  assert.ok(recordFunction.indexOf("FROM henvalt.billing_measurements") < recordFunction.indexOf("SELECT status, provider_usage_record_id"));
  assert.ok(recordFunction.indexOf("FOR UPDATE;") < recordFunction.indexOf("SELECT status, provider_usage_record_id"));
  const resolveStart = migration.indexOf("CREATE OR REPLACE FUNCTION henvalt.control_plane_resolve_billing_reconciliation");
  const resolveFunction = migration.slice(resolveStart);
  assert.ok(resolveFunction.indexOf("FROM henvalt.billing_measurements") < resolveFunction.indexOf("FOR UPDATE OF buc"));
  assert.match(migration, /control_plane_get_billing_reconciliation/);
  assert.match(migration, /control_plane_list_billing_reconciliations/);
  assert.match(acceptance, /tenant-scoped reconciliation queue did not list the pending case/);
  assert.match(migration, /control_plane_resolve_billing_reconciliation/);
  assert.match(migration, /reconciliation_status = 'MATCHED'/);
  assert.match(migration, /NOT_FOUND_CONFIRMED/);
  assert.match(migration, /request.jwt.claim.role/);
  assert.match(migration, /v_safe_evidence := jsonb_build_object/);
  assert.match(migration, /CREATE UNIQUE INDEX billing_usage_charges_provider_record_unique/);
  assert.match(acceptance, /duplicate provider usage record was attached to a second charge/);
  assert.match(migration, /reconciliation_evidence = v_safe_evidence/);
  assert.match(acceptance, /arbitrary evidence key was persisted/);
  assert.match(acceptance, /matched reconciliation failed/);
  assert.match(acceptance, /retry did not preserve original charge identity and idempotency key/);
  assert.equal((migration.match(/'testMode', v_test_mode/g) || []).length, 2);
  assert.match(acceptance, /live-mode subscription was not blocked by default/);
  assert.match(migration, /FULLY_OFFSET_BY_REFUND_CREDIT/);
  assert.match(migration, /amount, currency, status, attempt_count, attempted_at/);
  assert.match(migration, /v_charge\.amount/);
  assert.match(migration, /REVOKE ALL ON FUNCTION henvalt\.control_plane_claim_billing_usage/);
  assert.match(migration, /GRANT EXECUTE ON FUNCTION henvalt\.control_plane_claim_billing_usage\(text\)\s+TO service_role/);
});

test("PostgreSQL acceptance covers partial, full, exhausted and retry-safe refund credits", () => {
  assert.match(acceptance, /BILLING_REFUND_CREDIT_OFFSETS_ACCEPTANCE_PASSED/);
  assert.match(acceptance, /billing usage claim RPC must not be executable by client roles/);
  assert.match(acceptance, /billing credit allocations must have row-level security enabled/);
  assert.match(acceptance, /expected net \$7 charge/);
  assert.match(acceptance, /retry duplicated refund credit allocation/);
  assert.match(acceptance, /fully credited measurement was not voided/);
  assert.match(acceptance, /remaining \$2 credit was not applied/);
});

test("safety CI applies and exercises the refund-credit migration", () => {
  assert.match(workflow, /202611220011_billing_refund_credit_offsets\.sql/);
  assert.match(workflow, /billing-refund-credit-offsets-postgres-acceptance\.sql/);
});

test("concurrent workers serialize on credit rows and re-read the balance after lock acquisition", () => {
  assert.match(migration, /fresh READ COMMITTED statement snapshot/);
  assert.match(migration, /SELECT abs\(cbm\.henvalt_fee\) - COALESCE\(sum\(o\.amount\), 0\)/);
  assert.match(migration, /FOR UPDATE OF cbm\s*LOOP/);
  assert.match(concurrency, /BILLING_REFUND_CREDIT_CONCURRENCY_ACCEPTANCE_PASSED/);
  assert.match(concurrency, /"amount":\[\[:space:\]\]\*7/);
  assert.match(concurrency, /worker B incorrectly reused or lost the locked credit/);
  assert.doesNotMatch(concurrency, /\$[0-9]+/);
  assert.match(workflow, /billing-refund-credit-concurrency-postgres\.sh/);
  assert.match(workflow, /node --test[\s\S]*tests\/billing-refund-credit-offsets\.test\.mjs/);
  assert.match(acceptance, /late refund credit rewrote an already-created pending charge/);
  assert.match(acceptance, /late refund credit was not applied to the next charge/);
});

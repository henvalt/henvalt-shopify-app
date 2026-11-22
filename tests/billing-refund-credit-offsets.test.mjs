import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const migration = readFileSync(new URL("../supabase/migrations/202611220011_billing_refund_credit_offsets.sql", import.meta.url), "utf8");
const acceptance = readFileSync(new URL("./billing-refund-credit-offsets-postgres-acceptance.sql", import.meta.url), "utf8");
const workflow = readFileSync(new URL("../.github/workflows/provider-send-interlock-static.yml", import.meta.url), "utf8");
const concurrency = readFileSync(new URL("./billing-refund-credit-concurrency-postgres.sh", import.meta.url), "utf8");

test("refund fee credits are tenant-scoped, currency-scoped, locked and allocated once", () => {
  assert.match(migration, /billing_measurement_credit_offsets/);
  assert.match(migration, /ALTER TABLE henvalt\.billing_measurement_credit_offsets ENABLE ROW LEVEL SECURITY/);
  assert.match(migration, /UNIQUE \(tenant_id, credit_measurement_id, charge_measurement_id\)/);
  assert.match(migration, /FOR UPDATE OF cbm\s*LOOP/);\n  assert.doesNotMatch(migration, /FOR UPDATE OF cbm SKIP LOCKED/);
  assert.match(migration, /cbm\.currency = v_currency/);
  assert.match(migration, /crl\.entry_type = 'ADJUSTMENT'/);
  assert.match(migration, /crl\.attribution_confidence = 'CONFIRMED'/);
  assert.match(migration, /v_remaining := v_remaining - v_apply/);
  assert.match(migration, /FULLY_OFFSET_BY_REFUND_CREDIT/);
  assert.match(migration, /amount, currency, status, attempt_count, attempted_at/);
  assert.match(migration, /v_charge\.amount/);
  assert.match(migration, /REVOKE ALL ON FUNCTION henvalt\.control_plane_claim_billing_usage/);
  assert.match(migration, /GRANT EXECUTE ON FUNCTION henvalt\.control_plane_claim_billing_usage\(text\)\s+TO service_role/);
});

test("PostgreSQL acceptance covers partial, full, exhausted and retry-safe refund credits", () => {
  assert.match(acceptance, /BILLING_REFUND_CREDIT_OFFSETS_ACCEPTANCE_PASSED/);
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
  assert.match(concurrency, /worker B incorrectly reused or lost the locked credit/);
  assert.doesNotMatch(concurrency, /\$[0-9]+/);
  assert.match(workflow, /billing-refund-credit-concurrency-postgres\.sh/);
});

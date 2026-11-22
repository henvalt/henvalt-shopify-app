import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const migration = readFileSync(
  new URL("../supabase/migrations/202611220010_promote_confirmed_recovery_ledger.sql", import.meta.url),
  "utf8",
);
const workflow = readFileSync(
  new URL("../.github/workflows/provider-send-interlock-static.yml", import.meta.url),
  "utf8",
);
const acceptance = readFileSync(
  new URL("./revenue-ledger-attribution-promotion-postgres-acceptance.sql", import.meta.url),
  "utf8",
);

test("recovery ledger promotion is monotonic and only confirmed attribution is billable", () => {
  assert.match(migration, /v_confidence NOT IN \('CONFIRMED', 'PROBABLE'\)/);
  assert.match(migration, /v_confidence = 'CONFIRMED'/);
  assert.match(migration, /attribution_confidence = 'CONFIRMED'/);
  assert.match(migration, /billable = true/);
  assert.match(migration, /v_existing_confidence IS DISTINCT FROM 'CONFIRMED'/);
  assert.match(migration, /ON CONFLICT \(tenant_id, order_id\)/);
  assert.match(migration, /WHERE entry_type = 'RECOVERY'/);
  assert.match(migration, /FOR UPDATE OF oa, o/);
  assert.match(migration, /lower\(COALESCE\(v_financial_status, ''\)\) <> 'paid'/);
  assert.match(migration, /v_cancelled_at IS NOT NULL/);
});

test("CI applies the migration and runs its disposable PostgreSQL acceptance", () => {
  assert.match(workflow, /202611220010_promote_confirmed_recovery_ledger\.sql/);
  assert.match(workflow, /revenue-ledger-attribution-promotion-postgres-acceptance\.sql/);
  assert.match(acceptance, /REVENUE_LEDGER_CONFIRMED_PROMOTION_ACCEPTANCE_PASSED/);
});

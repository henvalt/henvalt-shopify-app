import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const source = readFileSync("supabase/functions/henvalt-merchant-dashboard/index.ts", "utf8");

test("candidate merchant dashboard preserves the deployed v4 ledger response contract", () => {
  assert.match(source, /revenue_ledger\?/);
  assert.match(source, /attribution_confidence: "eq\.CONFIRMED"/);
  assert.match(source, /billing_measurements!billing_measurements_ledger_entry_id_fkey/);
  assert.match(source, /ledger,/);
  assert.match(source, /revenueComparison:/);
});

test("candidate merchant dashboard keeps the confirmed revenue series and comparison fields", () => {
  assert.match(source, /p_granularity: "day"/);
  assert.match(source, /currentRevenue: revenue\?\.current_revenue/);
  assert.match(source, /previousRevenue: revenue\?\.previous_revenue/);
  assert.match(source, /changePercent: revenue\?\.change_percent/);
});

test("ledger query is tenant-scoped, confirmed-only, bounded and end-exclusive", () => {
  assert.match(source, /tenant_id: "eq\." \+ tenantId/);
  assert.match(source, /entry_type: "eq\.RECOVERY"/);
  assert.match(source, /attribution_confidence: "eq\.CONFIRMED"/);
  assert.match(source, /created_at: "gte\." \+ from/);
  assert.match(source, /created_at\.lt\." \+ toExclusive/);
  assert.match(source, /limit: "50"/);
  assert.match(source, /if \(!Array\.isArray\(ledger\)\) throw new Error\("REVENUE_LEDGER_INVALID_RESPONSE"\)/);
});

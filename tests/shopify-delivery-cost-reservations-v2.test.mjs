import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

const migration = readFileSync(
  new URL('../supabase/migrations/202611170008_shopify_delivery_cost_reservations_v2.sql', import.meta.url),
  'utf8'
);

test('delivery cost reservations are merchant-wide, explicit-currency, and fail closed', () => {
  assert.match(migration, /email_unit_cost_amount numeric\(18,6\)/);
  assert.match(migration, /email_unit_cost_currency text/);
  assert.match(migration, /v_provider\.email_unit_cost_currency <>[\s\S]*?v_billing\.currency/);
  assert.match(migration, /FOR UPDATE/);
  assert.match(migration, /status IN \('RESERVED','SETTLED'\)/);
  assert.match(migration, /v_reserved \+ v_provider\.email_unit_cost_amount > v_billing\.usage_cap_amount/);
  assert.match(migration, /v_monthly_count > v_billing\.monthly_email_limit/);
  assert.match(migration, /AFTER INSERT ON henvalt\.shopify_recovery_send_attempt_v2/);
  assert.match(migration, /WHEN NEW\.status='SUBMITTED' THEN 'SETTLED'/);
  assert.match(migration, /WHEN NEW\.status='FAILED' THEN 'RELEASED'/);
  assert.match(migration, /WHEN NEW\.status='AMBIGUOUS' THEN 'RESERVED'/);
  assert.doesNotMatch(migration, /UPDATE henvalt\.shopify_delivery_cost_reservations_v2[\s\S]{0,300}WHEN NEW\.status='AMBIGUOUS' THEN 'RELEASED'/);
});

test('delivery context preflights configured provider cost before releasing secrets', () => {
  assert.match(migration, /CREATE OR REPLACE FUNCTION henvalt\.resolve_shopify_delivery_context_v2/);
  assert.match(migration, /pr\.email_unit_cost_amount/);
  assert.match(migration, /pr\.email_unit_cost_currency/);
  assert.match(migration, /email_unit_cost_currency <> pg_catalog\.upper/);
  assert.doesNotMatch(migration, /MONETARY_USAGE_RESERVATION_REQUIRED/);
  assert.match(migration, /consume inserts[\s\S]*?migration-019 trigger reserves merchant-wide cost atomically/);
});

import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

const migration = readFileSync(
  new URL('../supabase/migrations/202611260010_validate_shopify_recovery_parent_links.sql', import.meta.url),
  'utf8'
);

test('intervention sequence must belong to the same tenant and opportunity', () => {
  assert.match(migration, /from henvalt\.recovery_sequences rs/);
  assert.match(migration, /v_sequence_tenant_id is distinct from v_tenant_id/);
  assert.match(migration, /v_sequence_opportunity_id is distinct from new\.opportunity_id/);
  assert.match(migration, /SHOPIFY_CONNECTION_SCOPE_SEQUENCE_OPPORTUNITY_MISMATCH/);
  assert.match(migration, /SHOPIFY_CONNECTION_SCOPE_SEQUENCE_STORE_MISMATCH/);
});

test('delivery request opportunity is derived from and locked to its intervention', () => {
  assert.match(migration, /from henvalt\.recovery_interventions ri/);
  assert.match(migration, /new\.opportunity_id := v_intervention_opportunity_id/);
  assert.match(migration, /new\.opportunity_id is distinct from v_intervention_opportunity_id/);
  assert.match(migration, /SHOPIFY_CONNECTION_SCOPE_DELIVERY_OPPORTUNITY_MISMATCH/);
  assert.match(migration, /SHOPIFY_CONNECTION_SCOPE_DELIVERY_STORE_MISMATCH/);
});

test('parent-link validation runs on insert and every relevant re-parenting update', () => {
  assert.match(migration, /before insert or update of tenant_id, shopify_connection_id, opportunity_id, sequence_id/);
  assert.match(migration, /before insert or update of tenant_id, shopify_connection_id, opportunity_id, intervention_id/);
});

test('validator is not directly executable by public client roles', () => {
  assert.match(migration, /revoke all on function henvalt\.validate_shopify_recovery_parent_links\(\) from public, anon, authenticated/);
  assert.match(migration, /grant execute on function henvalt\.validate_shopify_recovery_parent_links\(\) to service_role/);
});

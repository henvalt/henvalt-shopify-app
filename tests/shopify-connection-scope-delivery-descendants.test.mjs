import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

const migration = readFileSync(
  new URL('../supabase/migrations/202611260008_propagate_shopify_connection_to_delivery_descendants.sql', import.meta.url),
  'utf8'
);

test('recovery sequences and delivery attempts carry connection foreign keys', () => {
  assert.match(migration, /alter table henvalt\.recovery_sequences add column if not exists shopify_connection_id uuid/i);
  assert.match(migration, /alter table henvalt\.delivery_attempts add column if not exists shopify_connection_id uuid/i);
  assert.match(migration, /recovery_sequences_shopify_connection_id_fkey/);
  assert.match(migration, /delivery_attempts_shopify_connection_id_fkey/);
});

test('recovery sequences inherit connection identity from opportunity', () => {
  assert.match(migration, /tg_table_name in \('recovery_sequences','recovery_interventions'\)/);
  assert.match(migration, /from henvalt\.opportunities o where o\.id=v_opportunity_id/);
});

test('delivery attempts inherit connection identity from delivery request', () => {
  assert.match(migration, /tg_table_name='delivery_attempts'/);
  assert.match(migration, /from henvalt\.delivery_requests dr where dr\.id=v_delivery_id/);
  assert.match(migration, /SHOPIFY_CONNECTION_SCOPE_DELIVERY_PARENT_MISMATCH/);
});

test('descendant lineage rejects tenant or parent mismatches', () => {
  assert.match(migration, /SHOPIFY_CONNECTION_SCOPE_PARENT_MISMATCH/);
  assert.match(migration, /SHOPIFY_CONNECTION_SCOPE_NOT_ACTIVE_FOR_TENANT/);
});

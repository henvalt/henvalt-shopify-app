import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

const migration = readFileSync(
  new URL('../supabase/migrations/202611260007_propagate_shopify_connection_to_recovery_graph.sql', import.meta.url),
  'utf8'
);

test('recovery graph tables carry nullable connection foreign keys', () => {
  for (const table of ['customers','checkouts','orders','sessions','opportunities','recovery_interventions','delivery_requests']) {
    assert.match(migration, new RegExp('alter table henvalt\\.'+table+' add column if not exists shopify_connection_id uuid','i'));
    assert.match(migration, new RegExp(table+'_shopify_connection_id_fkey|t\\|\\|\\x27_shopify_connection_id_fkey'));
  }
});

test('orders and opportunities inherit identity from canonical source events', () => {
  assert.match(migration, /tg_table_name in \('orders','opportunities'\)/);
  assert.match(migration, /canonical_events ce/);
  assert.match(migration, /ce\.shopify_connection_id/);
  assert.match(migration, /SHOPIFY_CONNECTION_SCOPE_EVENT_PARENT_MISMATCH/);
});

test('recovery interventions and delivery requests inherit identity from parent records', () => {
  assert.match(migration, /from henvalt\.opportunities o where o\.id=v_opportunity_id/);
  assert.match(migration, /from henvalt\.recovery_interventions ri where ri\.id=v_intervention_id/);
  assert.match(migration, /SHOPIFY_CONNECTION_SCOPE_PARENT_MISMATCH/);
  assert.match(migration, /SHOPIFY_CONNECTION_SCOPE_CUSTOMER_STORE_MISMATCH/);
  assert.match(migration, /SHOPIFY_CONNECTION_SCOPE_CHECKOUT_STORE_MISMATCH/);
  assert.match(migration, /update of shopify_connection_id,metadata,source_event_id,customer_id,checkout_id/);
  assert.match(migration, /update of shopify_connection_id,intervention_id,opportunity_id/);
});

test('connection identity must be active and belong to the same tenant', () => {
  assert.match(migration, /where sc\.id=v_connection_id and sc\.active=true/);
  assert.match(migration, /v_parent_tenant_id is distinct from v_tenant_id/);
  assert.match(migration, /SHOPIFY_CONNECTION_SCOPE_NOT_ACTIVE_FOR_TENANT/);
});

test('historical rows are not guessed or backfilled', () => {
  assert.doesNotMatch(migration, /update henvalt\.(customers|checkouts|orders|sessions|opportunities|recovery_interventions|delivery_requests)\s+set shopify_connection_id/i);
});

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

const identityGuard = readFileSync(
  new URL('../supabase/migrations/20261126150000_guard_shopify_connection_identity_immutable.sql', import.meta.url),
  'utf8'
);

test('captured Shopify connection and tenant identity cannot be re-parented or cleared', () => {
  assert.match(identityGuard, /SHOPIFY_CONNECTION_IDENTITY_IMMUTABLE/);
  assert.match(identityGuard, /v_new_connection_id is distinct from v_old_connection_id/);
  assert.match(identityGuard, /v_new_tenant_id is distinct from v_old_tenant_id/);
  assert.match(identityGuard, /SHOPIFY_CONNECTION_IDENTITY_TENANT_MISMATCH/);
  assert.match(identityGuard, /sc\.active=true/);
});

test('Shopify webhook and canonical event source identity cannot be rewritten', () => {
  assert.match(identityGuard, /SHOPIFY_EVENT_SOURCE_IDENTITY_IMMUTABLE/);
  assert.match(identityGuard, /before update of tenant_id, shopify_connection_id, source[\s\S]*?on henvalt\.webhook_events/);
  assert.match(identityGuard, /before update of tenant_id, shopify_connection_id, source[\s\S]*?on henvalt\.canonical_events/);
});

test('identity guard covers every connection-scoped descendant and is service-role only', () => {
  for (const table of [
    'webhook_events','canonical_events','customers','checkouts','orders','sessions',
    'opportunities','recovery_sequences','recovery_interventions','delivery_requests','delivery_attempts'
  ]) {
    assert.match(identityGuard, new RegExp('on henvalt\.' + table + '\\b'));
  }
  assert.match(identityGuard, /revoke all on function henvalt\.guard_shopify_connection_identity_immutable\(\)[\s\S]*?from public, anon, authenticated/);
  assert.match(identityGuard, /grant execute on function henvalt\.guard_shopify_connection_identity_immutable\(\)[\s\S]*?to service_role/);
});


test('identity guard runs after trigger-derived identity changes on every update', () => {
  assert.equal((identityGuard.match(/before update\s+on henvalt\./g) || []).length, 11);
  assert.doesNotMatch(identityGuard, /before update of tenant_id, shopify_connection_id/);
  assert.match(identityGuard, /if v_new_connection_id is not null and v_old_connection_id is null then/);
  assert.match(identityGuard, /Existing rows must[\s\S]*?remain mutable for non-identity fields even if their connection is later/);
});

import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

const migration = readFileSync(
  new URL('../supabase/migrations/202611260005_capture_shopify_connection_at_ingress.sql', import.meta.url),
  'utf8'
);

test('webhook and canonical event rows have explicit connection foreign keys', () => {
  assert.match(migration, /alter table henvalt\.webhook_events[\s\S]*?add column if not exists shopify_connection_id uuid/i);
  assert.match(migration, /alter table henvalt\.canonical_events[\s\S]*?add column if not exists shopify_connection_id uuid/i);
  assert.match(migration, /webhook_events_shopify_connection_id_fkey[\s\S]*?references henvalt\.shopify_connections\(id\)/i);
  assert.match(migration, /canonical_events_shopify_connection_id_fkey[\s\S]*?references henvalt\.shopify_connections\(id\)/i);
});

test('new Shopify webhooks require one globally unique active shop connection', () => {
  const body = migration.split('create or replace function henvalt.capture_shopify_webhook_connection_scope')[1]
    .split('drop trigger if exists trg_capture_shopify_webhook_connection_scope')[0];
  assert.match(body, /metadata->>'shop_domain'/);
  assert.match(body, /sc\.active = true/);
  assert.match(body, /t\.status = 'ACTIVE'/);
  assert.match(body, /v_match_count <> 1/);
  assert.match(body, /v_match_tenant_id is distinct from new\.tenant_id/);
  assert.match(body, /SHOPIFY_WEBHOOK_SHOP_DOMAIN_MISSING_OR_INVALID/);
});

test('canonical Shopify events inherit scope from their verified webhook', () => {
  const body = migration.split('create or replace function henvalt.capture_canonical_event_connection_scope')[1]
    .split('drop trigger if exists trg_capture_canonical_event_connection_scope')[0];
  assert.match(body, /w\.shopify_connection_id/);
  assert.match(body, /w\.tenant_id/);
  assert.match(body, /SHOPIFY_CANONICAL_EVENT_CONNECTION_SCOPE_MISSING/);
  assert.match(body, /SHOPIFY_CANONICAL_EVENT_CONNECTION_SCOPE_MISMATCH/);
});

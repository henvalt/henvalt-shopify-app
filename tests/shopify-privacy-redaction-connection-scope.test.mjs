import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

const migration = readFileSync(
  new URL('../supabase/migrations/202611260003_privacy_redaction_fail_closed_until_connection_scope.sql', import.meta.url),
  'utf8'
);

test('customer redaction lease wrapper fails closed without tenant-wide deletion', () => {
  const body = migration.split('create or replace function henvalt.redact_shopify_customer_data_checked_with_lease')[1]
    .split('create or replace function henvalt.redact_shopify_shop_data_with_lease')[0];
  assert.match(body, /topic <> 'customers\/redact'/);
  assert.match(body, /lease_token is distinct from p_lease_token/);
  assert.match(body, /'review_required', true/);
  assert.match(body, /'matched', false/);
  assert.doesNotMatch(body, /redact_shopify_customer_data_checked\s*\(/);
});

test('shop redaction lease wrapper never invokes tenant deletion', () => {
  const body = migration.split('create or replace function henvalt.redact_shopify_shop_data_with_lease')[1];
  assert.match(body, /topic <> 'shop\/redact'/);
  assert.match(body, /lease_token is distinct from p_lease_token/);
  assert.match(body, /'review_required', true/);
  assert.match(body, /'completed', false/);
  assert.doesNotMatch(body, /redact_shopify_shop_data\s*\(/);
  assert.doesNotMatch(body, /delete\s+from\s+henvalt\.tenants/i);
});

test('redaction wrappers remain service-role-only', () => {
  assert.match(migration, /revoke all on function henvalt\.redact_shopify_customer_data_checked_with_lease\(uuid, uuid\)\s+from public, anon, authenticated/i);
  assert.match(migration, /revoke all on function henvalt\.redact_shopify_shop_data_with_lease\(uuid, uuid\)\s+from public, anon, authenticated/i);
  assert.match(migration, /grant execute on function henvalt\.redact_shopify_customer_data_checked_with_lease\(uuid, uuid\)\s+to service_role/i);
  assert.match(migration, /grant execute on function henvalt\.redact_shopify_shop_data_with_lease\(uuid, uuid\)\s+to service_role/i);
});

#!/usr/bin/env bash
set -euo pipefail

psql -v ON_ERROR_STOP=1 -c "begin; select henvalt.control_plane_finalize_shopify_oauth_install_expiring_for_owner('state-user-a','race-shop.myshopify.com','access-token-user-a-1234567890','refresh-token-user-a-1234567890',3600,86400,'shop-100',array['read_orders'],'aaaaaaaa-0000-4000-8000-000000000001'); select pg_sleep(2); commit;" > /tmp/henvalt-oauth-owner-a.log 2>&1 &
owner_a_pid=$!
sleep 0.2

set +e
psql -v ON_ERROR_STOP=1 -c "begin; select henvalt.control_plane_finalize_shopify_oauth_install_expiring_for_owner('state-user-b','race-shop.myshopify.com','access-token-user-b-1234567890','refresh-token-user-b-1234567890',3600,86400,'shop-100',array['read_orders'],'bbbbbbbb-0000-4000-8000-000000000002'); commit;" > /tmp/henvalt-oauth-owner-b.log 2>&1
owner_b_status=$?
set -e

wait "$owner_a_pid"
if [ "$owner_b_status" -eq 0 ]; then
  echo "FAIL: concurrent second owner claim unexpectedly succeeded"
  exit 1
fi
grep -q "tenant_already_claimed" /tmp/henvalt-oauth-owner-b.log

result="$(psql -At -v ON_ERROR_STOP=1 -c "select tm.user_id::text || '|' || s.secret from henvalt.tenant_memberships tm join henvalt.shopify_connections sc on sc.tenant_id=tm.tenant_id join vault.secrets s on s.id=sc.access_token_secret_ref::uuid where sc.shop_domain='race-shop.myshopify.com' and s.name='henvalt_shop_race-shop_myshopify_com_access'")"
expected="aaaaaaaa-0000-4000-8000-000000000001|access-token-user-a-1234567890"
if [ "$result" != "$expected" ]; then
  echo "FAIL: owner/token state after concurrent claims was unexpected: $result"
  exit 1
fi
echo "PASS: concurrent OAuth callbacks serialize; first owner retains membership and Shopify token"

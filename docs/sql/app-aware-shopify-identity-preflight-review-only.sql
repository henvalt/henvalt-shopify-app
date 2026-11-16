-- HENVALT app-aware Shopify identity readiness preflight
-- REVIEW ONLY / SELECT ONLY. This file is NOT a migration.
-- It must not be used with apply_migration. No schema/data/secrets/workflows change.
-- Run only after code review, using a read-only database role where available.

-- 1) Confirm current identity columns and whether proposed columns already exist.
SELECT table_name, column_name, data_type, is_nullable
FROM information_schema.columns
WHERE table_schema = 'henvalt'
  AND table_name IN ('shopify_connections', 'shopify_oauth_states',
                     'webhook_events', 'canonical_events', 'pixel_keys')
  AND column_name IN ('id', 'tenant_id', 'shop_domain', 'state_hash',
                      'app_key', 'shopify_connection_id',
                      'access_token_secret_ref', 'refresh_token_secret_ref')
ORDER BY table_name, ordinal_position;

-- 2) Confirm shop-domain uniqueness remains in place before any app-aware work.
SELECT c.conname, pg_get_constraintdef(c.oid) AS definition
FROM pg_constraint c
JOIN pg_class t ON t.oid = c.conrelid
JOIN pg_namespace n ON n.oid = t.relnamespace
WHERE n.nspname = 'henvalt'
  AND t.relname = 'shopify_connections'
  AND c.contype IN ('p','u','f')
ORDER BY c.conname;

-- 3) Count connection cardinality without returning domains, tokens or tenant IDs.
SELECT count(*) AS connection_rows,
       count(*) FILTER (WHERE active) AS active_connections,
       count(*) FILTER (WHERE NOT active) AS inactive_connections,
       count(DISTINCT tenant_id) AS tenants_with_connections
FROM henvalt.shopify_connections;

-- 4) Detect duplicate normalized shop domains. Expected result: zero rows.
SELECT lower(btrim(shop_domain)) AS normalized_shop_domain,
       count(*) AS row_count
FROM henvalt.shopify_connections
GROUP BY lower(btrim(shop_domain))
HAVING count(*) > 1
ORDER BY row_count DESC;

-- 5) Count OAuth state records by lifecycle without exposing state hashes or user IDs.
SELECT count(*) AS state_rows,
       count(*) FILTER (WHERE consumed_at IS NULL AND expires_at > now()) AS unconsumed_unexpired,
       count(*) FILTER (WHERE consumed_at IS NOT NULL) AS consumed,
       count(*) FILTER (WHERE expires_at <= now()) AS expired
FROM henvalt.shopify_oauth_states;

-- 6) Confirm app-aware objects are absent/present without reading secret values.
SELECT 'shopify_app_registry' AS object_name,
       to_regclass('henvalt.shopify_app_registry') IS NOT NULL AS exists
UNION ALL
SELECT 'shopify_connections.app_key',
       EXISTS (SELECT 1 FROM information_schema.columns
               WHERE table_schema='henvalt' AND table_name='shopify_connections' AND column_name='app_key')
UNION ALL
SELECT 'shopify_oauth_states.app_key',
       EXISTS (SELECT 1 FROM information_schema.columns
               WHERE table_schema='henvalt' AND table_name='shopify_oauth_states' AND column_name='app_key')
UNION ALL
SELECT 'webhook_events.shopify_connection_id',
       EXISTS (SELECT 1 FROM information_schema.columns
               WHERE table_schema='henvalt' AND table_name='webhook_events' AND column_name='shopify_connection_id')
UNION ALL
SELECT 'canonical_events.shopify_connection_id',
       EXISTS (SELECT 1 FROM information_schema.columns
               WHERE table_schema='henvalt' AND table_name='canonical_events' AND column_name='shopify_connection_id');

-- 7) Inventory current and proposed RPC names/signatures. No function body or secret values.
SELECT p.proname, p.oid::regprocedure::text AS signature, p.prosecdef
FROM pg_proc p
JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'henvalt'
  AND p.proname IN (
    'verify_shopify_webhook_hmac',
    'resolve_shopify_tenant',
    'control_plane_connect_shop',
    'control_plane_finalize_shopify_oauth_install_expiring_for_owner',
    'claim_shopify_token_refresh',
    'complete_shopify_token_refresh',
    'fail_shopify_token_refresh',
    'verify_shopify_webhook_hmac_v2',
    'resolve_shopify_connection_v2',
    'finalize_shopify_oauth_install_v2'
  )
ORDER BY p.proname, p.oid::regprocedure::text;

-- 8) Verify RLS is enabled and no ordinary client table grants have appeared
-- on the proposed app registry if/when it is created.
SELECT c.relname AS table_name,
       c.relrowsecurity AS rls_enabled,
       c.relforcerowsecurity AS force_rls
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname='henvalt'
  AND c.relname IN ('shopify_app_registry','shopify_connections','shopify_oauth_states')
ORDER BY c.relname;

SELECT table_name, grantee, privilege_type
FROM information_schema.role_table_grants
WHERE table_schema='henvalt'
  AND table_name IN ('shopify_app_registry','shopify_connections','shopify_oauth_states')
  AND grantee IN ('anon','authenticated','service_role')
ORDER BY table_name, grantee, privilege_type;

-- Interpretation:
-- - shopify_connections.shop_domain must remain unique for initial rollout.
-- - Existing rows must be classified from verified provenance before app_key backfill.
-- - A second app identity must never update an existing connection's Vault refs.
-- - Empty app-aware object checks are expected before implementation.
-- - Do not use current active connection count as proof of historical lineage.

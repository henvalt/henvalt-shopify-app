-- READ-ONLY preflight for Shopify webhook identity foundation.
-- Run before any future application of the candidate migration.
-- This file contains SELECT statements only.

SELECT 'existing_target_objects' AS check_name,
       jsonb_agg(c.relname ORDER BY c.relname) AS result
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = 'henvalt'
  AND c.relname IN (
    'shopify_app_registry',
    'shopify_webhook_route_tokens',
    'shopify_webhook_deliveries'
  );

SELECT 'connection_domain_normalization_collisions' AS check_name,
       lower(btrim(shop_domain)) AS normalized_domain,
       count(*) AS row_count
FROM henvalt.shopify_connections
GROUP BY lower(btrim(shop_domain))
HAVING count(*) > 1;

SELECT 'noncanonical_connection_domains' AS check_name,
       count(*) AS row_count
FROM henvalt.shopify_connections
WHERE shop_domain <> lower(btrim(shop_domain));

SELECT 'connections_without_app_identity' AS check_name,
       count(*) FILTER (WHERE to_jsonb(sc)->>'app_key' IS NULL) AS unresolved_connection_count
FROM henvalt.shopify_connections sc;

SELECT 'legacy_webhook_event_rows' AS check_name,
       count(*) AS legacy_rows_that_will_remain_unattributed
FROM henvalt.webhook_events;

-- New inbox table does not exist until the candidate migration is applied.
-- Its connection-scoped delivery uniqueness is enforced by the migration itself.

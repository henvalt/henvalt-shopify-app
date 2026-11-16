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

SELECT 'connections_without_app_identity' AS check_name,
       count(*) AS unresolved_connection_count
FROM henvalt.shopify_connections
WHERE app_key IS NULL;

SELECT 'legacy_webhook_event_rows' AS check_name,
       count(*) AS legacy_rows_that_will_remain_unattributed
FROM henvalt.webhook_events;

SELECT 'webhook_delivery_id_duplicates_within_connection' AS check_name,
       connection_id,
       shopify_delivery_id,
       count(*) AS duplicate_count
FROM henvalt.shopify_webhook_deliveries
GROUP BY connection_id, shopify_delivery_id
HAVING count(*) > 1;

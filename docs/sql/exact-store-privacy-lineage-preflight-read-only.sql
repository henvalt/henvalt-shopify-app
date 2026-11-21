-- READ-ONLY exact-store privacy lineage preflight.
-- Safe to execute against production: SELECT statements only, aggregate metadata
-- only, no customer identifiers, emails, payloads, secrets, DDL or DML.

WITH required_tables(table_name) AS (
  VALUES
    ('customers'),
    ('checkouts'),
    ('orders'),
    ('sessions'),
    ('session_aliases'),
    ('canonical_events'),
    ('webhook_events'),
    ('opportunities'),
    ('recovery_interventions'),
    ('delivery_requests'),
    ('delivery_attempts'),
    ('customer_conversations'),
    ('conversation_messages'),
    ('messages'),
    ('tracking_tokens'),
    ('unsubscribe_tokens'),
    ('email_suppressions'),
    ('provider_events'),
    ('processing_errors'),
    ('background_jobs'),
    ('audit_log'),
    ('shopify_privacy_requests')
)
SELECT
  r.table_name,
  to_regclass('henvalt.' || r.table_name) IS NOT NULL AS table_exists,
  EXISTS (
    SELECT 1 FROM information_schema.columns c
    WHERE c.table_schema = 'henvalt'
      AND c.table_name = r.table_name
      AND c.column_name = 'shopify_connection_id'
  ) AS has_shopify_connection_id,
  EXISTS (
    SELECT 1 FROM information_schema.columns c
    WHERE c.table_schema = 'henvalt'
      AND c.table_name = r.table_name
      AND c.column_name = 'app_key'
  ) AS has_app_key
FROM required_tables r
ORDER BY r.table_name;

SELECT
  count(*) AS shopify_connection_count,
  count(DISTINCT tenant_id) AS tenant_count,
  count(DISTINCT shop_domain) AS unique_shop_domain_count
FROM henvalt.shopify_connections;

SELECT
  to_regclass('henvalt.shopify_app_registry') AS app_registry,
  to_regclass('henvalt.shopify_webhook_route_tokens') AS route_tokens,
  to_regclass('henvalt.shopify_webhook_deliveries') AS verified_webhook_inbox,
  to_regclass('henvalt.shopify_privacy_webhook_deliveries') AS verified_privacy_inbox;

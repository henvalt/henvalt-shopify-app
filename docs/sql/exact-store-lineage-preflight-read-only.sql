-- HENVALT exact-store lineage preflight
-- READ-ONLY ONLY. Run in Supabase SQL editor for review.
-- This script emits aggregate counts only; it does not expose shop domains,
-- customer emails, customer IDs, tokens, payload values, or secret material.
-- It performs no DDL, DML, function calls with side effects, or data changes.

WITH table_counts AS (
  SELECT 'shopify_connections' AS table_name, count(*)::bigint AS row_count FROM henvalt.shopify_connections
  UNION ALL SELECT 'webhook_events', count(*) FROM henvalt.webhook_events
  UNION ALL SELECT 'canonical_events', count(*) FROM henvalt.canonical_events
  UNION ALL SELECT 'pixel_keys', count(*) FROM henvalt.pixel_keys
  UNION ALL SELECT 'customers', count(*) FROM henvalt.customers
  UNION ALL SELECT 'sessions', count(*) FROM henvalt.sessions
  UNION ALL SELECT 'session_aliases', count(*) FROM henvalt.session_aliases
  UNION ALL SELECT 'checkouts', count(*) FROM henvalt.checkouts
  UNION ALL SELECT 'orders', count(*) FROM henvalt.orders
  UNION ALL SELECT 'opportunities', count(*) FROM henvalt.opportunities
  UNION ALL SELECT 'recovery_sequences', count(*) FROM henvalt.recovery_sequences
  UNION ALL SELECT 'recovery_interventions', count(*) FROM henvalt.recovery_interventions
  UNION ALL SELECT 'delivery_requests', count(*) FROM henvalt.delivery_requests
  UNION ALL SELECT 'delivery_attempts', count(*) FROM henvalt.delivery_attempts
  UNION ALL SELECT 'customer_conversations', count(*) FROM henvalt.customer_conversations
  UNION ALL SELECT 'conversation_messages', count(*) FROM henvalt.conversation_messages
  UNION ALL SELECT 'order_attributions', count(*) FROM henvalt.order_attributions
  UNION ALL SELECT 'revenue_ledger', count(*) FROM henvalt.revenue_ledger
  UNION ALL SELECT 'email_usage_measurements', count(*) FROM henvalt.email_usage_measurements
  UNION ALL SELECT 'shopify_privacy_requests', count(*) FROM henvalt.shopify_privacy_requests
  UNION ALL SELECT 'unsubscribe_tokens', count(*) FROM henvalt.unsubscribe_tokens
  UNION ALL SELECT 'email_suppressions', count(*) FROM henvalt.email_suppressions
),
connection_summary AS (
  SELECT
    (SELECT count(*) FROM henvalt.shopify_connections) AS connections,
    (SELECT count(*) FROM henvalt.shopify_connections WHERE active) AS active_connections,
    (SELECT count(*) FROM (
      SELECT tenant_id FROM henvalt.shopify_connections
      GROUP BY tenant_id HAVING count(*) > 1
    ) multi) AS tenants_with_multiple_connections,
    (SELECT count(*) FROM henvalt.pixel_keys) AS pixel_keys,
    (SELECT count(*) FROM henvalt.pixel_keys WHERE active AND revoked_at IS NULL) AS active_pixel_keys
),
webhook_domain_resolution AS (
  SELECT
    w.id,
    nullif(lower(btrim(w.metadata->>'shop_domain')), '') AS normalized_shop_domain,
    (SELECT count(*) FROM henvalt.shopify_connections sc
      WHERE lower(sc.shop_domain) = lower(btrim(w.metadata->>'shop_domain'))) AS matching_connections
  FROM henvalt.webhook_events w
),
canonical_source AS (
  SELECT
    e.id,
    e.tenant_id,
    e.source,
    e.event_type,
    e.webhook_event_id,
    w.id AS parent_id,
    w.tenant_id AS parent_tenant_id,
    wd.normalized_shop_domain,
    wd.matching_connections
  FROM henvalt.canonical_events e
  LEFT JOIN henvalt.webhook_events w ON w.id = e.webhook_event_id
  LEFT JOIN webhook_domain_resolution wd ON wd.id = w.id
),
resolution_summary AS (
  SELECT
    (SELECT count(*) FROM webhook_domain_resolution WHERE normalized_shop_domain IS NOT NULL) AS webhook_rows_with_shop_domain,
    (SELECT count(*) FROM webhook_domain_resolution WHERE normalized_shop_domain IS NOT NULL AND matching_connections = 1) AS webhook_rows_uniquely_matching_connection,
    (SELECT count(*) FROM webhook_domain_resolution WHERE normalized_shop_domain IS NULL OR matching_connections <> 1) AS webhook_rows_unresolved_or_ambiguous,
    (SELECT count(*) FROM canonical_source WHERE webhook_event_id IS NOT NULL) AS canonical_rows_with_webhook_parent,
    (SELECT count(*) FROM canonical_source WHERE webhook_event_id IS NOT NULL AND parent_id IS NULL) AS canonical_rows_with_missing_parent,
    (SELECT count(*) FROM canonical_source WHERE webhook_event_id IS NOT NULL AND parent_tenant_id IS DISTINCT FROM tenant_id) AS canonical_rows_with_tenant_mismatch,
    (SELECT count(*) FROM canonical_source WHERE webhook_event_id IS NOT NULL AND matching_connections = 1) AS canonical_rows_with_unique_shop_metadata_match,
    (SELECT count(*) FROM canonical_source WHERE webhook_event_id IS NOT NULL AND (matching_connections IS NULL OR matching_connections <> 1)) AS canonical_rows_without_unique_shop_metadata_match,
    (SELECT count(*) FROM canonical_source WHERE webhook_event_id IS NULL) AS canonical_rows_without_webhook_parent,
    (SELECT count(*) FROM canonical_source WHERE webhook_event_id IS NULL AND source = 'SHOPIFY_WEB_PIXEL') AS pixel_canonical_rows_without_webhook_parent
),
duplicate_groups AS (
  SELECT 'customers tenant + Shopify customer ID' AS identity_key, count(*)::bigint AS duplicate_groups,
         coalesce(sum(n - 1), 0)::bigint AS excess_rows
  FROM (SELECT tenant_id, shopify_customer_id, count(*) n FROM henvalt.customers
        WHERE shopify_customer_id IS NOT NULL GROUP BY tenant_id, shopify_customer_id HAVING count(*) > 1) x
  UNION ALL
  SELECT 'checkouts tenant + Shopify checkout ID', count(*)::bigint, coalesce(sum(n - 1), 0)::bigint
  FROM (SELECT tenant_id, shopify_checkout_id, count(*) n FROM henvalt.checkouts
        WHERE shopify_checkout_id IS NOT NULL GROUP BY tenant_id, shopify_checkout_id HAVING count(*) > 1) x
  UNION ALL
  SELECT 'checkouts tenant + checkout token', count(*)::bigint, coalesce(sum(n - 1), 0)::bigint
  FROM (SELECT tenant_id, checkout_token, count(*) n FROM henvalt.checkouts
        WHERE checkout_token IS NOT NULL GROUP BY tenant_id, checkout_token HAVING count(*) > 1) x
  UNION ALL
  SELECT 'orders tenant + Shopify order ID', count(*)::bigint, coalesce(sum(n - 1), 0)::bigint
  FROM (SELECT tenant_id, shopify_order_id, count(*) n FROM henvalt.orders
        WHERE shopify_order_id IS NOT NULL GROUP BY tenant_id, shopify_order_id HAVING count(*) > 1) x
  UNION ALL
  SELECT 'sessions tenant + session reference', count(*)::bigint, coalesce(sum(n - 1), 0)::bigint
  FROM (SELECT tenant_id, session_reference, count(*) n FROM henvalt.sessions
        GROUP BY tenant_id, session_reference HAVING count(*) > 1) x
  UNION ALL
  SELECT 'webhooks tenant + idempotency key', count(*)::bigint, coalesce(sum(n - 1), 0)::bigint
  FROM (SELECT tenant_id, idempotency_key, count(*) n FROM henvalt.webhook_events
        GROUP BY tenant_id, idempotency_key HAVING count(*) > 1) x
  UNION ALL
  SELECT 'canonical events tenant + idempotency key', count(*)::bigint, coalesce(sum(n - 1), 0)::bigint
  FROM (SELECT tenant_id, idempotency_key, count(*) n FROM henvalt.canonical_events
        GROUP BY tenant_id, idempotency_key HAVING count(*) > 1) x
  UNION ALL
  SELECT 'opportunities tenant + idempotency key', count(*)::bigint, coalesce(sum(n - 1), 0)::bigint
  FROM (SELECT tenant_id, idempotency_key, count(*) n FROM henvalt.opportunities
        GROUP BY tenant_id, idempotency_key HAVING count(*) > 1) x
  UNION ALL
  SELECT 'interventions tenant + idempotency key', count(*)::bigint, coalesce(sum(n - 1), 0)::bigint
  FROM (SELECT tenant_id, idempotency_key, count(*) n FROM henvalt.recovery_interventions
        GROUP BY tenant_id, idempotency_key HAVING count(*) > 1) x
)
SELECT jsonb_build_object(
  'table_counts', (SELECT jsonb_agg(jsonb_build_object('table', table_name, 'rows', row_count) ORDER BY table_name) FROM table_counts),
  'connection_summary', (SELECT to_jsonb(connection_summary) FROM connection_summary),
  'resolution_summary', (SELECT to_jsonb(resolution_summary) FROM resolution_summary),
  'duplicate_groups', (SELECT jsonb_agg(jsonb_build_object('key', identity_key, 'groups', duplicate_groups, 'excess_rows', excess_rows) ORDER BY identity_key) FROM duplicate_groups)
) AS exact_store_preflight;

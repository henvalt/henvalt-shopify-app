-- HENVALT store-identity migration preflight (REVIEW ONLY)
-- ---------------------------------------------------------------------------
-- SAFETY: This file is intentionally SELECT-only. It does not alter schema,
-- data, functions, policies, secrets, or workflow state.
-- DO NOT APPLY as a migration. Run manually only after code review.
--
-- Purpose:
--   1) quantify rows with explicit metadata.shop_domain;
--   2) distinguish same-tenant matches, missing markers, unknown shops and
--      tenant/connection conflicts;
--   3) provide evidence for a deterministic backfill plan.
--
-- Never infer a connection from "the only currently active connection".
-- Rows without explicit and trusted lineage remain unresolved.

WITH connection_map AS (
  SELECT id AS shopify_connection_id,
         tenant_id,
         lower(shop_domain) AS shop_domain,
         active
  FROM henvalt.shopify_connections
),
source_rows AS (
  SELECT 'webhook_events'::text AS source_table,
         id,
         tenant_id,
         nullif(lower(btrim(metadata->>'shop_domain')), '') AS shop_domain
  FROM henvalt.webhook_events

  UNION ALL
  SELECT 'canonical_events',
         id,
         tenant_id,
         nullif(lower(btrim(metadata->>'shop_domain')), '')
  FROM henvalt.canonical_events

  UNION ALL
  SELECT 'customers',
         id,
         tenant_id,
         nullif(lower(btrim(metadata->>'shop_domain')), '')
  FROM henvalt.customers

  UNION ALL
  SELECT 'checkouts',
         id,
         tenant_id,
         nullif(lower(btrim(metadata->>'shop_domain')), '')
  FROM henvalt.checkouts

  UNION ALL
  SELECT 'opportunities',
         id,
         tenant_id,
         nullif(lower(btrim(metadata->>'shop_domain')), '')
  FROM henvalt.opportunities
),
classified AS (
  SELECT s.*,
         cm.shopify_connection_id,
         cm.tenant_id AS connection_tenant_id,
         cm.active AS connection_active,
         CASE
           WHEN s.shop_domain IS NULL THEN 'MISSING_SHOP_MARKER'
           WHEN cm.shopify_connection_id IS NULL THEN 'SHOP_NOT_FOUND'
           WHEN cm.tenant_id <> s.tenant_id THEN 'TENANT_CONNECTION_CONFLICT'
           ELSE 'MATCHED_SAME_TENANT'
         END AS mapping_state
  FROM source_rows s
  LEFT JOIN connection_map cm
    ON cm.shop_domain = s.shop_domain
)
SELECT source_table,
       count(*) AS total_rows,
       count(*) FILTER (WHERE mapping_state = 'MATCHED_SAME_TENANT') AS same_tenant_match,
       count(*) FILTER (WHERE mapping_state = 'MISSING_SHOP_MARKER') AS missing_shop_marker,
       count(*) FILTER (WHERE mapping_state = 'SHOP_NOT_FOUND') AS unknown_shop_domain,
       count(*) FILTER (WHERE mapping_state = 'TENANT_CONNECTION_CONFLICT') AS tenant_connection_conflict,
       count(*) FILTER (WHERE mapping_state = 'MATCHED_SAME_TENANT' AND connection_active) AS matched_active_connection,
       count(*) FILTER (WHERE mapping_state = 'MATCHED_SAME_TENANT' AND NOT connection_active) AS matched_inactive_connection
FROM classified
GROUP BY source_table
ORDER BY source_table;

-- Row-level review of unresolved or conflicting mappings. Do not backfill
-- these rows automatically; reconcile against immutable event lineage first.
WITH connection_map AS (
  SELECT id AS shopify_connection_id,
         tenant_id,
         lower(shop_domain) AS shop_domain,
         active
  FROM henvalt.shopify_connections
),
source_rows AS (
  SELECT 'webhook_events'::text AS source_table, id, tenant_id,
         nullif(lower(btrim(metadata->>'shop_domain')), '') AS shop_domain
  FROM henvalt.webhook_events
  UNION ALL
  SELECT 'canonical_events', id, tenant_id,
         nullif(lower(btrim(metadata->>'shop_domain')), '')
  FROM henvalt.canonical_events
  UNION ALL
  SELECT 'customers', id, tenant_id,
         nullif(lower(btrim(metadata->>'shop_domain')), '')
  FROM henvalt.customers
  UNION ALL
  SELECT 'checkouts', id, tenant_id,
         nullif(lower(btrim(metadata->>'shop_domain')), '')
  FROM henvalt.checkouts
  UNION ALL
  SELECT 'opportunities', id, tenant_id,
         nullif(lower(btrim(metadata->>'shop_domain')), '')
  FROM henvalt.opportunities
)
SELECT s.source_table, s.id, s.tenant_id, s.shop_domain,
       cm.shopify_connection_id,
       cm.tenant_id AS connection_tenant_id,
       cm.active AS connection_active,
       CASE
         WHEN s.shop_domain IS NULL THEN 'MISSING_SHOP_MARKER'
         WHEN cm.shopify_connection_id IS NULL THEN 'SHOP_NOT_FOUND'
         WHEN cm.tenant_id <> s.tenant_id THEN 'TENANT_CONNECTION_CONFLICT'
         ELSE 'MATCHED_SAME_TENANT'
       END AS mapping_state
FROM source_rows s
LEFT JOIN connection_map cm ON cm.shop_domain = s.shop_domain
WHERE s.shop_domain IS NULL
   OR cm.shopify_connection_id IS NULL
   OR cm.tenant_id <> s.tenant_id
ORDER BY s.source_table, s.id;

-- Connection cardinality and tenant fan-out snapshot.
SELECT sc.tenant_id,
       count(*) AS connection_count,
       count(*) FILTER (WHERE sc.active) AS active_connection_count,
       array_agg(sc.shop_domain ORDER BY sc.shop_domain) AS shop_domains
FROM henvalt.shopify_connections sc
GROUP BY sc.tenant_id
HAVING count(*) > 1
ORDER BY sc.tenant_id;

-- Index/constraint collision checks must be added only after the final
-- connection-scoped uniqueness keys are selected. Existing tenant-scoped
-- unique constraints are deliberately not modified by this review file.

-- HENVALT candidate-query cross-store ambiguity diagnostics (REVIEW ONLY)
-- -----------------------------------------------------------------------
-- SAFETY: SELECT-only diagnostics. No schema, row, function, or workflow
-- is changed. Do not apply this file as a migration.
--
-- These queries quantify source records that the current candidate RPCs can
-- associate with more than one active connection because their joins use
-- tenant_id without a trusted shop/connection predicate.

-- 1) Tenants whose active connections create fan-out risk.
SELECT sc.tenant_id,
       count(*) AS active_connection_count,
       array_agg(lower(sc.shop_domain) ORDER BY lower(sc.shop_domain)) AS active_shops
FROM henvalt.shopify_connections sc
WHERE sc.active IS TRUE
GROUP BY sc.tenant_id
HAVING count(*) > 1
ORDER BY active_connection_count DESC, sc.tenant_id;

-- 2) Cart snapshots under a multi-store tenant. The deployed cart candidate
-- function joins these events to all active connections belonging to the
-- tenant even when metadata.shop_domain is populated; the domain is selected
-- later but is not used in the connection join.
WITH multi_store AS (
  SELECT tenant_id
  FROM henvalt.shopify_connections
  WHERE active IS TRUE
  GROUP BY tenant_id
  HAVING count(*) > 1
)
SELECT e.tenant_id,
       e.id AS canonical_event_id,
       e.event_type,
       e.session_reference,
       e.metadata->>'shop_domain' AS event_shop_domain,
       e.occurred_at,
       count(sc.id) AS active_connections_that_current_join_can_match,
       array_agg(lower(sc.shop_domain) ORDER BY lower(sc.shop_domain)) AS candidate_shop_domains
FROM henvalt.canonical_events e
JOIN multi_store ms ON ms.tenant_id = e.tenant_id
JOIN henvalt.shopify_connections sc
  ON sc.tenant_id = e.tenant_id AND sc.active IS TRUE
WHERE e.source = 'shopify'
  AND e.event_type = 'carts/update'
  AND e.session_reference IS NOT NULL
GROUP BY e.tenant_id, e.id, e.event_type, e.session_reference, e.metadata->>'shop_domain', e.occurred_at
ORDER BY e.occurred_at DESC;

-- 3) Browse/pixel events under a multi-store tenant. The deployed browse
-- candidate joins active connections by tenant and does not constrain the
-- connection join using event metadata.
WITH multi_store AS (
  SELECT tenant_id
  FROM henvalt.shopify_connections
  WHERE active IS TRUE
  GROUP BY tenant_id
  HAVING count(*) > 1
)
SELECT e.tenant_id,
       e.id AS canonical_event_id,
       e.event_type,
       e.session_reference,
       e.customer_reference,
       e.metadata->>'shop_domain' AS event_shop_domain,
       e.occurred_at,
       count(sc.id) AS active_connections_that_current_join_can_match,
       array_agg(lower(sc.shop_domain) ORDER BY lower(sc.shop_domain)) AS candidate_shop_domains
FROM henvalt.canonical_events e
JOIN multi_store ms ON ms.tenant_id = e.tenant_id
JOIN henvalt.shopify_connections sc
  ON sc.tenant_id = e.tenant_id AND sc.active IS TRUE
WHERE e.source = 'SHOPIFY_WEB_PIXEL'
  AND upper(e.event_type) IN ('PRODUCT_VIEWED', 'PRODUCT_ADDED_TO_CART')
  AND e.session_reference IS NOT NULL
GROUP BY e.tenant_id, e.id, e.event_type, e.session_reference,
         e.customer_reference, e.metadata->>'shop_domain', e.occurred_at
ORDER BY e.occurred_at DESC;

-- 4) Tenant-level customer/checkout/opportunity rows without a shop marker
-- in tenants that have more than one active connection. These rows cannot be
-- safely assigned to a store using active-connection count or email alone.
WITH multi_store AS (
  SELECT tenant_id
  FROM henvalt.shopify_connections
  WHERE active IS TRUE
  GROUP BY tenant_id
  HAVING count(*) > 1
),
source_rows AS (
  SELECT 'customers'::text AS source_table, id, tenant_id,
         metadata->>'shop_domain' AS shop_domain
  FROM henvalt.customers
  UNION ALL
  SELECT 'checkouts', id, tenant_id, metadata->>'shop_domain'
  FROM henvalt.checkouts
  UNION ALL
  SELECT 'opportunities', id, tenant_id, metadata->>'shop_domain'
  FROM henvalt.opportunities
)
SELECT s.source_table, s.id, s.tenant_id, s.shop_domain
FROM source_rows s
JOIN multi_store ms ON ms.tenant_id = s.tenant_id
WHERE nullif(lower(btrim(s.shop_domain)), '') IS NULL
ORDER BY s.source_table, s.id;

-- 5) Same external customer IDs appearing in different shop markers within
-- a tenant. This is a diagnostic for source identity collisions; no changes.
SELECT c.tenant_id,
       c.shopify_customer_id,
       count(*) AS customer_rows,
       count(DISTINCT lower(nullif(c.metadata->>'shop_domain',''))) AS distinct_shop_markers,
       array_agg(DISTINCT lower(nullif(c.metadata->>'shop_domain',''))) AS shop_markers
FROM henvalt.customers c
WHERE nullif(c.shopify_customer_id, '') IS NOT NULL
GROUP BY c.tenant_id, c.shopify_customer_id
HAVING count(DISTINCT lower(nullif(c.metadata->>'shop_domain',''))) > 1
ORDER BY c.tenant_id, c.shopify_customer_id;

-- HENVALT Shopify privacy deadline and queue monitor V2.
-- PREPARATION ONLY. Read-only operational visibility; no alert delivery or processing action.

BEGIN;

CREATE OR REPLACE VIEW henvalt.shopify_privacy_deadline_monitor_v2
WITH (security_barrier = true)
AS
SELECT
  r.id AS receipt_id,
  r.app_key,
  r.tenant_id,
  r.connection_id,
  r.shop_domain,
  r.topic,
  r.received_at,
  r.received_at + interval '30 days' AS deadline_at,
  GREATEST(0, floor(EXTRACT(epoch FROM (pg_catalog.now() - r.received_at))))::bigint AS age_seconds,
  floor(EXTRACT(epoch FROM (r.received_at + interval '30 days' - pg_catalog.now())))::bigint
    AS deadline_seconds_remaining,
  j.state AS processing_job_state,
  COALESCE(j.attempt_count, 0) AS attempt_count,
  j.lease_until,
  (sc.id IS NOT NULL) AS connection_binding_valid,
  (
    r.topic = 'shop/redact'
    OR (r.topic IN ('customers/data_request', 'customers/redact') AND r.customer_id IS NOT NULL)
  ) AS customer_scope_complete,
  CASE
    WHEN j.state = 'COMPLETED' THEN 'COMPLETED'
    WHEN COALESCE(j.attempt_count, 0) >= 10 THEN 'RETRY_LIMIT_REACHED'
    WHEN r.received_at + interval '30 days' <= pg_catalog.now() THEN 'OVERDUE'
    WHEN sc.id IS NULL
      OR (r.topic IN ('customers/data_request', 'customers/redact') AND r.customer_id IS NULL)
      THEN 'IDENTITY_REVIEW_REQUIRED'
    WHEN j.receipt_id IS NULL THEN 'QUEUE_MISSING'
    WHEN j.state = 'FAILED' THEN 'PROCESSING_FAILED'
    WHEN j.state = 'REVIEW_REQUIRED' THEN 'REVIEW_REQUIRED'
    WHEN j.state = 'CLAIMED' AND j.lease_until <= pg_catalog.now() THEN 'CLAIM_LEASE_EXPIRED'
    WHEN r.received_at + interval '30 days' <= pg_catalog.now() + interval '7 days'
      THEN 'DUE_WITHIN_7_DAYS'
    WHEN r.received_at + interval '30 days' <= pg_catalog.now() + interval '14 days'
      THEN 'DUE_WITHIN_14_DAYS'
    ELSE 'ON_TRACK'
  END AS deadline_status,
  (
    j.state IS DISTINCT FROM 'COMPLETED'
    AND (
      COALESCE(j.attempt_count, 0) >= 10
      OR r.received_at + interval '30 days' <= pg_catalog.now() + interval '7 days'
      OR sc.id IS NULL
      OR (r.topic IN ('customers/data_request', 'customers/redact') AND r.customer_id IS NULL)
      OR j.receipt_id IS NULL
      OR j.state IN ('FAILED', 'REVIEW_REQUIRED')
      OR (j.state = 'CLAIMED' AND j.lease_until <= pg_catalog.now())
    )
  ) AS requires_attention
FROM henvalt.shopify_privacy_webhook_deliveries r
LEFT JOIN henvalt.shopify_privacy_processing_jobs_v2 j
  ON j.receipt_id = r.id
LEFT JOIN henvalt.shopify_connections sc
  ON sc.id = r.connection_id
 AND sc.tenant_id = r.tenant_id
 AND sc.app_key = r.app_key
 AND sc.shop_domain = r.shop_domain;

REVOKE ALL ON henvalt.shopify_privacy_deadline_monitor_v2
  FROM PUBLIC, anon, authenticated, service_role;
GRANT SELECT ON henvalt.shopify_privacy_deadline_monitor_v2 TO service_role;

COMMENT ON VIEW henvalt.shopify_privacy_deadline_monitor_v2 IS
  'Service-only read model for Shopify privacy request age, 30-day deadline, exact-store binding, queue state and attention flags. Does not send alerts or complete requests.';

COMMIT;

-- HENVALT exact-store cart and browse recovery source candidates V2.
-- PREPARATION ONLY. Depends on pixel inbox 008 and identity graph 009.
-- This migration stores candidate evidence only: no recipient PII, opportunity,
-- sequence, intervention, n8n job, provider call, attribution, or billing.
-- Analytics consent permits this bounded pseudonymous event processing.
-- Marketing consent is deliberately not treated as a send authorization.

BEGIN;

CREATE UNIQUE INDEX IF NOT EXISTS shopify_pixel_event_inbox_v2_id_tenant_connection_uidx
  ON henvalt.shopify_pixel_event_inbox_v2(id, tenant_id, shopify_connection_id);

CREATE TABLE IF NOT EXISTS henvalt.shopify_pixel_recovery_candidate_v2 (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id uuid NOT NULL,
  shopify_connection_id uuid NOT NULL,
  candidate_type text NOT NULL
    CHECK (candidate_type IN ('ABANDONED_CART', 'BROWSE_ABANDONMENT')),
  session_identity_id uuid NOT NULL,
  customer_identity_id uuid,
  source_inbox_event_id uuid NOT NULL,
  product_key text NOT NULL,
  product_context jsonb NOT NULL DEFAULT '{}'::jsonb,
  value_at_risk numeric(18,4),
  currency text,
  last_activity_at timestamptz NOT NULL,
  eligible_after timestamptz NOT NULL,
  status text NOT NULL DEFAULT 'READY_FOR_REVIEW'
    CHECK (status IN ('READY_FOR_REVIEW', 'SUPPRESSED', 'EXPIRED', 'PROMOTED')),
  idempotency_key text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT shopify_pixel_recovery_candidate_v2_value_nonnegative
    CHECK (value_at_risk IS NULL OR value_at_risk >= 0),
  CONSTRAINT shopify_pixel_recovery_candidate_v2_currency_format
    CHECK (currency IS NULL OR currency ~ '^[A-Z]{3}$'),
  CONSTRAINT shopify_pixel_recovery_candidate_v2_product_key_nonempty
    CHECK (length(btrim(product_key)) BETWEEN 1 AND 240),
  CONSTRAINT shopify_pixel_recovery_candidate_v2_idempotency_nonempty
    CHECK (length(btrim(idempotency_key)) BETWEEN 1 AND 160),
  CONSTRAINT shopify_pixel_recovery_candidate_v2_connection_tenant_fkey
    FOREIGN KEY (shopify_connection_id, tenant_id)
    REFERENCES henvalt.shopify_connections(id, tenant_id)
    ON UPDATE RESTRICT ON DELETE RESTRICT,
  CONSTRAINT shopify_pixel_recovery_candidate_v2_session_same_store_fkey
    FOREIGN KEY (session_identity_id, tenant_id, shopify_connection_id)
    REFERENCES henvalt.shopify_session_identity_v2(id, tenant_id, shopify_connection_id)
    ON UPDATE RESTRICT ON DELETE RESTRICT,
  CONSTRAINT shopify_pixel_recovery_candidate_v2_customer_same_store_fkey
    FOREIGN KEY (customer_identity_id, tenant_id, shopify_connection_id)
    REFERENCES henvalt.shopify_customer_identity_v2(id, tenant_id, shopify_connection_id)
    ON UPDATE RESTRICT ON DELETE SET NULL (customer_identity_id),
  CONSTRAINT shopify_pixel_recovery_candidate_v2_source_same_store_fkey
    FOREIGN KEY (source_inbox_event_id, tenant_id, shopify_connection_id)
    REFERENCES henvalt.shopify_pixel_event_inbox_v2(id, tenant_id, shopify_connection_id)
    ON UPDATE RESTRICT ON DELETE RESTRICT,
  CONSTRAINT shopify_pixel_recovery_candidate_v2_store_idempotency_uidx
    UNIQUE (shopify_connection_id, idempotency_key)
);

CREATE INDEX IF NOT EXISTS shopify_pixel_recovery_candidate_v2_ready_idx
  ON henvalt.shopify_pixel_recovery_candidate_v2(status, eligible_after)
  WHERE status = 'READY_FOR_REVIEW';

ALTER TABLE henvalt.shopify_pixel_recovery_candidate_v2 ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON henvalt.shopify_pixel_recovery_candidate_v2
  FROM PUBLIC, anon, authenticated, service_role;

COMMENT ON TABLE henvalt.shopify_pixel_recovery_candidate_v2 IS
  'Exact-store cart/browse candidate evidence only. No contact data or send authorization; final marketing consent and suppression must be rechecked by the delivery boundary.';

CREATE OR REPLACE FUNCTION henvalt.refresh_shopify_pixel_recovery_candidates_v2(
  p_inactivity_for interval DEFAULT interval '60 minutes',
  p_max_age interval DEFAULT interval '24 hours',
  p_limit integer DEFAULT 200
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_upserted integer := 0;
  v_suppressed integer := 0;
BEGIN
  IF p_inactivity_for IS NULL
     OR p_inactivity_for < interval '30 minutes'
     OR p_inactivity_for > interval '24 hours'
     OR p_max_age IS NULL
     OR p_max_age < p_inactivity_for
     OR p_max_age > interval '7 days'
     OR p_limit IS NULL OR p_limit < 1 OR p_limit > 500 THEN
    RETURN jsonb_build_object('accepted', false, 'code', 'INVALID_POLICY');
  END IF;

  -- A later same-store checkout start or cart removal invalidates an
  -- unpromoted cart candidate. Do not suppress on another store's session.
  UPDATE henvalt.shopify_pixel_recovery_candidate_v2 c
     SET status = 'SUPPRESSED', updated_at = pg_catalog.now()
   WHERE c.status = 'READY_FOR_REVIEW'
     AND c.candidate_type = 'ABANDONED_CART'
     AND EXISTS (
       SELECT 1
       FROM henvalt.shopify_pixel_event_inbox_v2 later
       WHERE later.tenant_id = c.tenant_id
         AND later.shopify_connection_id = c.shopify_connection_id
         AND later.client_reference = (
           SELECT s.session_reference
           FROM henvalt.shopify_session_identity_v2 s
           WHERE s.id = c.session_identity_id
             AND s.tenant_id = c.tenant_id
             AND s.shopify_connection_id = c.shopify_connection_id
         )
         AND later.analytics_processing_allowed IS TRUE
         AND later.status = 'PROCESSED'
         AND later.occurred_at > c.last_activity_at
         AND later.event_type IN ('product_removed_from_cart', 'checkout_started')
         AND (
           later.event_type = 'checkout_started'
           OR coalesce(later.payload #>> '{cart_line,product_id}',
                       later.payload #>> '{product,id}') = c.product_key
         )
     );
  GET DIAGNOSTICS v_suppressed = ROW_COUNT;

  WITH event_rows AS (
    SELECT
      e.id AS event_id,
      e.tenant_id,
      e.shopify_connection_id,
      e.event_type,
      e.occurred_at,
      e.payload,
      s.id AS session_identity_id,
      s.session_reference,
      s.customer_identity_id,
      CASE
        WHEN e.event_type = 'product_added_to_cart'
          THEN coalesce(e.payload #>> '{cart_line,product_id}',
                        e.payload #>> '{product,id}')
        ELSE e.payload #>> '{product,id}'
      END AS product_key,
      CASE
        WHEN e.event_type = 'product_added_to_cart'
          THEN coalesce(e.payload #>> '{cart_line,product_title}',
                        e.payload #>> '{product,title}')
        ELSE e.payload #>> '{product,title}'
      END AS product_title,
      CASE
        WHEN e.event_type = 'product_added_to_cart'
          THEN coalesce(e.payload #>> '{cart_line,unit_price_amount}',
                        e.payload #>> '{product,price_amount}')
        ELSE e.payload #>> '{product,price_amount}'
      END AS price_amount,
      CASE
        WHEN e.event_type = 'product_added_to_cart'
          THEN coalesce(e.payload #>> '{cart_line,currency}',
                        e.payload #>> '{product,price_currency}')
        ELSE e.payload #>> '{product,price_currency}'
      END AS price_currency,
      CASE
        WHEN e.event_type = 'product_added_to_cart'
          THEN coalesce(e.payload #>> '{cart_line,merchandise_id}',
                        e.payload #>> '{product,variant_id}')
        ELSE e.payload #>> '{product,variant_id}'
      END AS variant_key
    FROM henvalt.shopify_pixel_event_inbox_v2 e
    JOIN henvalt.shopify_session_identity_v2 s
      ON s.tenant_id = e.tenant_id
     AND s.shopify_connection_id = e.shopify_connection_id
     AND s.session_reference = e.client_reference
    JOIN henvalt.shopify_connections sc
      ON sc.id = e.shopify_connection_id
     AND sc.tenant_id = e.tenant_id
     AND sc.active IS TRUE
    JOIN henvalt.shopify_app_registry ar
      ON ar.app_key = sc.app_key
     AND ar.lifecycle_status = 'active'
    JOIN henvalt.tenants t
      ON t.id = e.tenant_id
     AND t.status = 'ACTIVE'
    WHERE e.status = 'PROCESSED'
      AND e.analytics_processing_allowed IS TRUE
      AND e.occurred_at >= pg_catalog.now() - p_max_age
      AND e.event_type IN ('product_viewed', 'product_added_to_cart')
  ),
  activity AS (
    SELECT
      er.*,
      (SELECT max(x.occurred_at)
       FROM henvalt.shopify_pixel_event_inbox_v2 x
       WHERE x.tenant_id = er.tenant_id
         AND x.shopify_connection_id = er.shopify_connection_id
         AND x.client_reference = er.session_reference
         AND x.status = 'PROCESSED'
         AND x.analytics_processing_allowed IS TRUE
      ) AS session_last_activity,
      (SELECT count(*)
       FROM henvalt.shopify_pixel_event_inbox_v2 v
       WHERE v.tenant_id = er.tenant_id
         AND v.shopify_connection_id = er.shopify_connection_id
         AND v.client_reference = er.session_reference
         AND v.status = 'PROCESSED'
         AND v.analytics_processing_allowed IS TRUE
         AND v.event_type = 'product_viewed'
         AND v.payload #>> '{product,id}' = er.product_key
         AND v.occurred_at >= pg_catalog.now() - p_max_age
      ) AS repeat_view_count,
      row_number() OVER (
        PARTITION BY er.shopify_connection_id, er.session_reference,
          er.event_type, er.product_key, coalesce(er.variant_key, '')
        ORDER BY er.occurred_at DESC, er.event_id DESC
      ) AS latest_rank
    FROM event_rows er
    WHERE er.product_key IS NOT NULL
      AND length(er.product_key) BETWEEN 1 AND 200
  ),
  eligible AS (
    SELECT
      a.*,
      CASE WHEN a.event_type = 'product_added_to_cart'
        THEN 'ABANDONED_CART' ELSE 'BROWSE_ABANDONMENT' END AS candidate_type,
      CASE WHEN a.event_type = 'product_added_to_cart'
        THEN coalesce(a.payload #>> '{cart_line,line_total_amount}',
                      a.payload #>> '{cart_line,unit_price_amount}',
                      a.payload #>> '{product,price_amount}')
        ELSE a.price_amount END AS candidate_value,
      CASE WHEN a.event_type = 'product_added_to_cart'
        THEN coalesce(a.payload #>> '{cart_line,currency}',
                      a.payload #>> '{product,price_currency}')
        ELSE a.price_currency END AS candidate_currency
    FROM activity a
    WHERE a.latest_rank = 1
      AND a.session_last_activity <= pg_catalog.now() - p_inactivity_for
      AND a.session_last_activity >= pg_catalog.now() - p_max_age
      AND (
        (a.event_type = 'product_added_to_cart')
        OR (a.event_type = 'product_viewed' AND a.repeat_view_count >= 2)
      )
      AND NOT EXISTS (
        SELECT 1
        FROM henvalt.shopify_pixel_event_inbox_v2 later
        WHERE later.tenant_id = a.tenant_id
          AND later.shopify_connection_id = a.shopify_connection_id
          AND later.client_reference = a.session_reference
          AND later.status = 'PROCESSED'
          AND later.analytics_processing_allowed IS TRUE
          AND later.occurred_at > a.occurred_at
          AND later.event_type IN (
            'product_added_to_cart', 'product_removed_from_cart', 'checkout_started'
          )
          AND (
            later.event_type = 'checkout_started'
            OR coalesce(later.payload #>> '{cart_line,product_id}',
                        later.payload #>> '{product,id}') = a.product_key
          )
      )
  ),
  inserted AS (
    INSERT INTO henvalt.shopify_pixel_recovery_candidate_v2 (
      tenant_id, shopify_connection_id, candidate_type,
      session_identity_id, customer_identity_id, source_inbox_event_id,
      product_key, product_context, value_at_risk, currency,
      last_activity_at, eligible_after, status, idempotency_key, updated_at
    )
    SELECT
      e.tenant_id, e.shopify_connection_id, e.candidate_type,
      e.session_identity_id, e.customer_identity_id, e.event_id,
      e.product_key,
      jsonb_strip_nulls(jsonb_build_object(
        'product_id', e.product_key,
        'product_title', e.product_title,
        'variant_id', e.variant_key
      )),
      CASE WHEN coalesce(e.candidate_value,'') ~ '^[0-9]{1,12}([.][0-9]{1,4})?$'
        THEN e.candidate_value::numeric ELSE NULL END,
      CASE WHEN upper(coalesce(e.candidate_currency,'')) ~ '^[A-Z]{3}$'
        THEN upper(e.candidate_currency) ELSE NULL END,
      e.session_last_activity,
      e.session_last_activity + p_inactivity_for,
      'READY_FOR_REVIEW',
      pg_catalog.encode(extensions.digest(
        pg_catalog.convert_to(
          e.shopify_connection_id::text || ':' || e.candidate_type || ':' ||
          e.session_reference || ':' || e.product_key || ':' ||
          coalesce(e.variant_key,''),
          'UTF8'
        ), 'sha256'
      ), 'hex'),
      pg_catalog.now()
    FROM eligible e
    ORDER BY e.session_last_activity
    LIMIT p_limit
    ON CONFLICT (shopify_connection_id, idempotency_key)
    DO UPDATE SET
      source_inbox_event_id = EXCLUDED.source_inbox_event_id,
      product_context = EXCLUDED.product_context,
      value_at_risk = EXCLUDED.value_at_risk,
      currency = EXCLUDED.currency,
      last_activity_at = EXCLUDED.last_activity_at,
      eligible_after = EXCLUDED.eligible_after,
      status = CASE
        WHEN henvalt.shopify_pixel_recovery_candidate_v2.status = 'PROMOTED'
          THEN 'PROMOTED'
        ELSE 'READY_FOR_REVIEW'
      END,
      updated_at = pg_catalog.now()
    RETURNING id
  )
  SELECT count(*)::integer INTO v_upserted FROM inserted;

  RETURN jsonb_build_object(
    'accepted', true,
    'candidates_upserted', v_upserted,
    'cart_or_browse_suppressed', v_suppressed,
    'delivery_authorized', false,
    'marketing_consent_checked_for_send', false
  );
END;
$function$;

REVOKE ALL ON FUNCTION henvalt.refresh_shopify_pixel_recovery_candidates_v2(interval,interval,integer)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION henvalt.refresh_shopify_pixel_recovery_candidates_v2(interval,interval,integer)
  TO service_role;

COMMIT;

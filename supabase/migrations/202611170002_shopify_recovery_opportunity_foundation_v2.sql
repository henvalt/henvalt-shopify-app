-- HENVALT exact-store checkout recovery opportunity foundation V2.
-- PREPARATION ONLY. Depends on candidate migrations 001, 009-012.
-- Promotes eligible checkouts to an opportunity record only. No contact
-- resolution, sequence, intervention, n8n enqueue, or delivery authorization.

BEGIN;

CREATE UNIQUE INDEX IF NOT EXISTS shopify_checkout_recovery_candidate_v2_id_tenant_connection_uidx
  ON henvalt.shopify_checkout_recovery_candidate_v2(id, tenant_id, shopify_connection_id);

CREATE TABLE IF NOT EXISTS henvalt.shopify_recovery_opportunity_v2 (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id uuid NOT NULL,
  shopify_connection_id uuid NOT NULL,
  app_key text NOT NULL,
  candidate_id uuid NOT NULL,
  checkout_identity_id uuid NOT NULL,
  customer_identity_id uuid,
  source_delivery_id uuid NOT NULL,
  opportunity_type text NOT NULL DEFAULT 'ABANDONED_CHECKOUT'
    CHECK (opportunity_type = 'ABANDONED_CHECKOUT'),
  status text NOT NULL
    CHECK (status IN ('CONTACT_RESOLUTION_PENDING','REVIEW_REQUIRED','CONVERTED','CLOSED')),
  value_at_risk numeric(18,4),
  currency text,
  idempotency_key text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT shopify_recovery_opportunity_v2_value_nonnegative
    CHECK (value_at_risk IS NULL OR value_at_risk >= 0),
  CONSTRAINT shopify_recovery_opportunity_v2_currency_format
    CHECK (currency IS NULL OR currency ~ '^[A-Z]{3}$'),
  CONSTRAINT shopify_recovery_opportunity_v2_idempotency_nonempty
    CHECK (length(btrim(idempotency_key)) BETWEEN 1 AND 160),
  CONSTRAINT shopify_recovery_opportunity_v2_app_fkey
    FOREIGN KEY (app_key) REFERENCES henvalt.shopify_app_registry(app_key)
    ON UPDATE RESTRICT ON DELETE RESTRICT,
  CONSTRAINT shopify_recovery_opportunity_v2_connection_app_fkey
    FOREIGN KEY (shopify_connection_id, tenant_id, app_key)
    REFERENCES henvalt.shopify_connections(id, tenant_id, app_key)
    ON UPDATE RESTRICT ON DELETE RESTRICT,
  CONSTRAINT shopify_recovery_opportunity_v2_candidate_same_store_fkey
    FOREIGN KEY (candidate_id, tenant_id, shopify_connection_id)
    REFERENCES henvalt.shopify_checkout_recovery_candidate_v2(id, tenant_id, shopify_connection_id)
    ON UPDATE RESTRICT ON DELETE RESTRICT,
  CONSTRAINT shopify_recovery_opportunity_v2_checkout_same_store_fkey
    FOREIGN KEY (checkout_identity_id, tenant_id, shopify_connection_id)
    REFERENCES henvalt.shopify_checkout_identity_v2(id, tenant_id, shopify_connection_id)
    ON UPDATE RESTRICT ON DELETE RESTRICT,
  CONSTRAINT shopify_recovery_opportunity_v2_customer_same_store_fkey
    FOREIGN KEY (customer_identity_id, tenant_id, shopify_connection_id)
    REFERENCES henvalt.shopify_customer_identity_v2(id, tenant_id, shopify_connection_id)
    ON UPDATE RESTRICT ON DELETE SET NULL (customer_identity_id),
  CONSTRAINT shopify_recovery_opportunity_v2_receipt_same_store_fkey
    FOREIGN KEY (source_delivery_id, tenant_id, shopify_connection_id)
    REFERENCES henvalt.shopify_webhook_deliveries(id, tenant_id, connection_id)
    ON UPDATE RESTRICT ON DELETE RESTRICT,
  CONSTRAINT shopify_recovery_opportunity_v2_candidate_uidx
    UNIQUE (candidate_id),
  CONSTRAINT shopify_recovery_opportunity_v2_store_idempotency_uidx
    UNIQUE (shopify_connection_id, idempotency_key)
);

CREATE INDEX IF NOT EXISTS shopify_recovery_opportunity_v2_pending_idx
  ON henvalt.shopify_recovery_opportunity_v2(status, created_at)
  WHERE status = 'CONTACT_RESOLUTION_PENDING';

ALTER TABLE henvalt.shopify_recovery_opportunity_v2 ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON henvalt.shopify_recovery_opportunity_v2
  FROM PUBLIC, anon, authenticated, service_role;

COMMENT ON TABLE henvalt.shopify_recovery_opportunity_v2 IS
  'Exact-store abandoned-checkout opportunity metadata only. No recipient PII, no sequence/intervention, and no delivery authorization.';

CREATE OR REPLACE FUNCTION henvalt.promote_shopify_checkout_recovery_candidates_v2(
  p_limit integer DEFAULT 100
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_created integer := 0;
  v_contact_pending integer := 0;
  v_review_required integer := 0;
BEGIN
  IF p_limit IS NULL OR p_limit < 1 OR p_limit > 500 THEN
    RETURN jsonb_build_object('accepted', false, 'code', 'INVALID_LIMIT');
  END IF;

  WITH selected AS (
    SELECT
      c.id AS candidate_id,
      c.tenant_id,
      c.shopify_connection_id,
      sc.app_key,
      c.checkout_identity_id,
      ch.customer_identity_id,
      c.source_delivery_id,
      ch.total_value AS value_at_risk,
      ch.currency,
      CASE
        WHEN ch.customer_identity_id IS NOT NULL
         AND ch.total_value IS NOT NULL
         AND ch.currency ~ '^[A-Z]{3}$'
          THEN 'CONTACT_RESOLUTION_PENDING'
        ELSE 'REVIEW_REQUIRED'
      END AS initial_status,
      pg_catalog.encode(
        extensions.digest(
          pg_catalog.convert_to(
            c.shopify_connection_id::text || ':' || c.checkout_token,
            'UTF8'
          ),
          'sha256'
        ),
        'hex'
      ) AS idempotency_key
    FROM henvalt.shopify_checkout_recovery_candidate_v2 c
    JOIN henvalt.shopify_checkout_identity_v2 ch
      ON ch.id = c.checkout_identity_id
     AND ch.tenant_id = c.tenant_id
     AND ch.shopify_connection_id = c.shopify_connection_id
    JOIN henvalt.shopify_connections sc
      ON sc.id = c.shopify_connection_id
     AND sc.tenant_id = c.tenant_id
     AND sc.active IS TRUE
    JOIN henvalt.shopify_app_registry ar
      ON ar.app_key = sc.app_key
     AND ar.lifecycle_status = 'active'
    JOIN henvalt.tenants t
      ON t.id = c.tenant_id
     AND t.status = 'ACTIVE'
    WHERE c.state = 'READY_FOR_CONTACT_RESOLUTION'
      AND c.eligible_after <= pg_catalog.now()
      AND ch.checkout_status = 'OPEN'
      AND NOT EXISTS (
        SELECT 1
        FROM henvalt.shopify_order_identity_v2 o
        WHERE o.tenant_id = c.tenant_id
          AND o.shopify_connection_id = c.shopify_connection_id
          AND o.checkout_token = c.checkout_token
      )
    ORDER BY c.eligible_after, c.id
    LIMIT p_limit
    FOR UPDATE OF c SKIP LOCKED
  ),
  inserted AS (
    INSERT INTO henvalt.shopify_recovery_opportunity_v2 (
      tenant_id, shopify_connection_id, app_key, candidate_id,
      checkout_identity_id, customer_identity_id, source_delivery_id,
      opportunity_type, status, value_at_risk, currency, idempotency_key,
      updated_at
    )
    SELECT
      s.tenant_id, s.shopify_connection_id, s.app_key, s.candidate_id,
      s.checkout_identity_id, s.customer_identity_id, s.source_delivery_id,
      'ABANDONED_CHECKOUT', s.initial_status, s.value_at_risk, s.currency,
      s.idempotency_key, pg_catalog.now()
    FROM selected s
    ON CONFLICT (candidate_id) DO NOTHING
    RETURNING status
  )
  SELECT
    count(*)::integer,
    count(*) FILTER (WHERE status = 'CONTACT_RESOLUTION_PENDING')::integer,
    count(*) FILTER (WHERE status = 'REVIEW_REQUIRED')::integer
  INTO v_created, v_contact_pending, v_review_required
  FROM inserted;

  RETURN jsonb_build_object(
    'accepted', true,
    'opportunities_created', v_created,
    'contact_resolution_pending', v_contact_pending,
    'review_required', v_review_required,
    'delivery_authorized', false
  );
END;
$function$;

REVOKE ALL ON FUNCTION henvalt.promote_shopify_checkout_recovery_candidates_v2(integer)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION henvalt.promote_shopify_checkout_recovery_candidates_v2(integer)
  TO service_role;

COMMIT;

-- HENVALT generalized exact-store recovery opportunities V2.
-- PREPARATION ONLY. Extends checkout-only opportunity metadata to reference
-- the cart/browse pixel candidate model. It deliberately creates no
-- intervention, sequence, delivery permit, provider request or billable row.

BEGIN;

ALTER TABLE henvalt.shopify_recovery_opportunity_v2
  ALTER COLUMN candidate_id DROP NOT NULL,
  ALTER COLUMN checkout_identity_id DROP NOT NULL,
  ALTER COLUMN source_delivery_id DROP NOT NULL,
  ADD COLUMN IF NOT EXISTS pixel_candidate_id uuid;

ALTER TABLE henvalt.shopify_recovery_opportunity_v2
  DROP CONSTRAINT IF EXISTS shopify_recovery_opportunity_v2_opportunity_type_check;

ALTER TABLE henvalt.shopify_recovery_opportunity_v2
  ADD CONSTRAINT shopify_recovery_opportunity_v2_opportunity_type_check
    CHECK (opportunity_type IN (
      'ABANDONED_CHECKOUT', 'ABANDONED_CART', 'BROWSE_ABANDONMENT'
    )),
  ADD CONSTRAINT shopify_recovery_opportunity_v2_source_shape_check
    CHECK (
      (
        opportunity_type = 'ABANDONED_CHECKOUT'
        AND candidate_id IS NOT NULL
        AND checkout_identity_id IS NOT NULL
        AND source_delivery_id IS NOT NULL
        AND pixel_candidate_id IS NULL
      )
      OR
      (
        opportunity_type IN ('ABANDONED_CART','BROWSE_ABANDONMENT')
        AND candidate_id IS NULL
        AND checkout_identity_id IS NULL
        AND source_delivery_id IS NULL
        AND pixel_candidate_id IS NOT NULL
      )
    );

CREATE UNIQUE INDEX IF NOT EXISTS shopify_pixel_recovery_candidate_v2_id_tenant_connection_uidx
  ON henvalt.shopify_pixel_recovery_candidate_v2(id,tenant_id,shopify_connection_id);

ALTER TABLE henvalt.shopify_recovery_opportunity_v2
  ADD CONSTRAINT shopify_recovery_opportunity_v2_pixel_candidate_fkey
    FOREIGN KEY (pixel_candidate_id,tenant_id,shopify_connection_id)
    REFERENCES henvalt.shopify_pixel_recovery_candidate_v2(id,tenant_id,shopify_connection_id)
    ON UPDATE RESTRICT ON DELETE RESTRICT;

CREATE UNIQUE INDEX IF NOT EXISTS shopify_recovery_opportunity_v2_pixel_candidate_uidx
  ON henvalt.shopify_recovery_opportunity_v2(pixel_candidate_id)
  WHERE pixel_candidate_id IS NOT NULL;

COMMENT ON COLUMN henvalt.shopify_recovery_opportunity_v2.pixel_candidate_id IS
  'Exact-store cart/browse source candidate. Delivery functions remain checkout-only until separately generalized and tested.';

CREATE OR REPLACE FUNCTION henvalt.promote_shopify_pixel_recovery_candidates_v2(
  p_limit integer DEFAULT 100
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_created integer := 0;
  v_review_required integer := 0;
  v_suppressed integer := 0;
  v_expired integer := 0;
BEGIN
  IF p_limit IS NULL OR p_limit < 1 OR p_limit > 500 THEN
    RETURN jsonb_build_object('accepted',false,'code','INVALID_LIMIT');
  END IF;

  -- Conversion and store lifecycle are rechecked at promotion, independently
  -- of the earlier pixel candidate refresh.
  UPDATE henvalt.shopify_pixel_recovery_candidate_v2 c
     SET status='SUPPRESSED',updated_at=pg_catalog.now()
   WHERE c.status='READY_FOR_REVIEW'
     AND c.customer_identity_id IS NOT NULL
     AND EXISTS (
       SELECT 1 FROM henvalt.shopify_order_identity_v2 o
       WHERE o.tenant_id=c.tenant_id
         AND o.shopify_connection_id=c.shopify_connection_id
         AND o.customer_identity_id=c.customer_identity_id
         AND o.ordered_at>=c.last_activity_at
         AND o.cancelled_at IS NULL
     );
  GET DIAGNOSTICS v_suppressed = ROW_COUNT;

  UPDATE henvalt.shopify_pixel_recovery_candidate_v2 c
     SET status='EXPIRED',updated_at=pg_catalog.now()
    FROM henvalt.shopify_connections sc
    JOIN henvalt.shopify_app_registry ar ON ar.app_key=sc.app_key
    JOIN henvalt.tenants t ON t.id=sc.tenant_id
   WHERE c.status='READY_FOR_REVIEW'
     AND sc.id=c.shopify_connection_id
     AND sc.tenant_id=c.tenant_id
     AND (
       sc.active IS DISTINCT FROM true
       OR ar.lifecycle_status<>'active'
       OR t.status<>'ACTIVE'
     );
  GET DIAGNOSTICS v_expired = ROW_COUNT;

  WITH selected AS (
    SELECT
      c.id AS pixel_candidate_id,
      c.tenant_id,
      c.shopify_connection_id,
      sc.app_key,
      c.customer_identity_id,
      c.candidate_type,
      c.value_at_risk,
      c.currency,
      c.idempotency_key,
      CASE WHEN c.customer_identity_id IS NOT NULL
        THEN 'CONTACT_RESOLUTION_PENDING'
        ELSE 'REVIEW_REQUIRED' END AS initial_status
    FROM henvalt.shopify_pixel_recovery_candidate_v2 c
    JOIN henvalt.shopify_connections sc
      ON sc.id=c.shopify_connection_id
     AND sc.tenant_id=c.tenant_id
     AND sc.active IS TRUE
    JOIN henvalt.shopify_app_registry ar
      ON ar.app_key=sc.app_key
     AND ar.lifecycle_status='active'
    JOIN henvalt.tenants t
      ON t.id=c.tenant_id
     AND t.status='ACTIVE'
    WHERE c.status='READY_FOR_REVIEW'
      AND c.eligible_after<=pg_catalog.now()
      AND NOT EXISTS (
        SELECT 1 FROM henvalt.shopify_order_identity_v2 o
        WHERE o.tenant_id=c.tenant_id
          AND o.shopify_connection_id=c.shopify_connection_id
          AND o.customer_identity_id=c.customer_identity_id
          AND o.ordered_at>=c.last_activity_at
          AND o.cancelled_at IS NULL
      )
    ORDER BY c.eligible_after,c.id
    LIMIT p_limit
    FOR UPDATE OF c SKIP LOCKED
  ),
  inserted AS (
    INSERT INTO henvalt.shopify_recovery_opportunity_v2 (
      tenant_id,shopify_connection_id,app_key,
      candidate_id,checkout_identity_id,customer_identity_id,source_delivery_id,
      pixel_candidate_id,opportunity_type,status,value_at_risk,currency,
      idempotency_key,updated_at
    )
    SELECT
      s.tenant_id,s.shopify_connection_id,s.app_key,
      NULL,NULL,s.customer_identity_id,NULL,
      s.pixel_candidate_id,s.candidate_type,s.initial_status,s.value_at_risk,s.currency,
      'pixel:'||s.idempotency_key,pg_catalog.now()
    FROM selected s
    ON CONFLICT (shopify_connection_id,idempotency_key) DO NOTHING
    RETURNING pixel_candidate_id,status
  ),
  marked AS (
    UPDATE henvalt.shopify_pixel_recovery_candidate_v2 c
       SET status='PROMOTED',updated_at=pg_catalog.now()
      FROM inserted i
     WHERE c.id=i.pixel_candidate_id
       AND c.status='READY_FOR_REVIEW'
    RETURNING i.status
  )
  SELECT
    count(*)::integer,
    count(*) FILTER (WHERE status='REVIEW_REQUIRED')::integer
  INTO v_created,v_review_required
  FROM inserted;

  RETURN jsonb_build_object(
    'accepted',true,
    'opportunities_created',v_created,
    'review_required',v_review_required,
    'suppressed_after_conversion',v_suppressed,
    'expired_inactive_store',v_expired,
    'interventions_created',false,
    'delivery_authorized',false,
    'marketing_consent_authorized',false
  );
END;
$function$;

REVOKE ALL ON FUNCTION henvalt.promote_shopify_pixel_recovery_candidates_v2(integer)
  FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION henvalt.promote_shopify_pixel_recovery_candidates_v2(integer)
  TO service_role;

COMMIT;

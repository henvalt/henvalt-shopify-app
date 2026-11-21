-- HENVALT exact-store checkout recovery eligibility V2.
-- PREPARATION ONLY. Depends on candidate migrations 001, 009, 010 and 011.
-- This creates eligibility records only. It does not resolve contact data,
-- create opportunities, schedule interventions, or authorize delivery.

BEGIN;

CREATE UNIQUE INDEX IF NOT EXISTS shopify_checkout_identity_v2_id_tenant_connection_uidx
  ON henvalt.shopify_checkout_identity_v2(id, tenant_id, shopify_connection_id);

CREATE TABLE IF NOT EXISTS henvalt.shopify_checkout_recovery_candidate_v2 (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id uuid NOT NULL,
  shopify_connection_id uuid NOT NULL,
  checkout_identity_id uuid NOT NULL,
  checkout_token text NOT NULL,
  source_delivery_id uuid NOT NULL,
  last_activity_at timestamptz NOT NULL,
  eligible_after timestamptz NOT NULL,
  state text NOT NULL DEFAULT 'READY_FOR_CONTACT_RESOLUTION'
    CHECK (state IN ('READY_FOR_CONTACT_RESOLUTION','CONVERTED','CHECKOUT_CLOSED','STORE_INACTIVE')),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT shopify_checkout_recovery_candidate_v2_token_nonempty
    CHECK (length(btrim(checkout_token)) BETWEEN 1 AND 255),
  CONSTRAINT shopify_checkout_recovery_candidate_v2_connection_tenant_fkey
    FOREIGN KEY (shopify_connection_id, tenant_id)
    REFERENCES henvalt.shopify_connections(id, tenant_id)
    ON UPDATE RESTRICT ON DELETE RESTRICT,
  CONSTRAINT shopify_checkout_recovery_candidate_v2_checkout_same_store_fkey
    FOREIGN KEY (checkout_identity_id, tenant_id, shopify_connection_id)
    REFERENCES henvalt.shopify_checkout_identity_v2(id, tenant_id, shopify_connection_id)
    ON UPDATE RESTRICT ON DELETE RESTRICT,
  CONSTRAINT shopify_checkout_recovery_candidate_v2_receipt_same_store_fkey
    FOREIGN KEY (source_delivery_id, tenant_id, shopify_connection_id)
    REFERENCES henvalt.shopify_webhook_deliveries(id, tenant_id, connection_id)
    ON UPDATE RESTRICT ON DELETE RESTRICT,
  CONSTRAINT shopify_checkout_recovery_candidate_v2_store_token_uidx
    UNIQUE (shopify_connection_id, checkout_token)
);

CREATE INDEX IF NOT EXISTS shopify_checkout_recovery_candidate_v2_ready_idx
  ON henvalt.shopify_checkout_recovery_candidate_v2(state, eligible_after)
  WHERE state = 'READY_FOR_CONTACT_RESOLUTION';

ALTER TABLE henvalt.shopify_checkout_recovery_candidate_v2 ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON henvalt.shopify_checkout_recovery_candidate_v2
  FROM PUBLIC, anon, authenticated, service_role;

COMMENT ON TABLE henvalt.shopify_checkout_recovery_candidate_v2 IS
  'Exact-store checkout eligibility only. Contains no shopper contact data and is not a delivery authorization or legacy recovery opportunity.';

CREATE OR REPLACE FUNCTION henvalt.refresh_shopify_checkout_recovery_candidates_v2(
  p_minimum_inactive_for interval,
  p_limit integer DEFAULT 100
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_upserted integer := 0;
  v_converted integer := 0;
  v_closed integer := 0;
BEGIN
  IF p_minimum_inactive_for IS NULL
     OR p_minimum_inactive_for < interval '15 minutes'
     OR p_minimum_inactive_for > interval '7 days'
     OR p_limit IS NULL OR p_limit < 1 OR p_limit > 500 THEN
    RETURN jsonb_build_object('accepted', false, 'code', 'INVALID_POLICY');
  END IF;

  UPDATE henvalt.shopify_checkout_recovery_candidate_v2 c
     SET state = 'CONVERTED', updated_at = pg_catalog.now()
    FROM henvalt.shopify_order_identity_v2 o
   WHERE o.shopify_connection_id = c.shopify_connection_id
     AND o.tenant_id = c.tenant_id
     AND o.checkout_token = c.checkout_token
     AND c.state <> 'CONVERTED';
  GET DIAGNOSTICS v_converted = ROW_COUNT;

  UPDATE henvalt.shopify_checkout_recovery_candidate_v2 c
     SET state = 'CHECKOUT_CLOSED', updated_at = pg_catalog.now()
    FROM henvalt.shopify_checkout_identity_v2 ch
   WHERE ch.id = c.checkout_identity_id
     AND ch.tenant_id = c.tenant_id
     AND ch.shopify_connection_id = c.shopify_connection_id
     AND ch.checkout_status <> 'OPEN'
     AND c.state = 'READY_FOR_CONTACT_RESOLUTION';
  GET DIAGNOSTICS v_closed = ROW_COUNT;

  WITH eligible AS (
    SELECT
      ch.id AS checkout_identity_id,
      ch.tenant_id,
      ch.shopify_connection_id,
      ch.shopify_checkout_token AS checkout_token,
      ch.source_delivery_id,
      ch.updated_at AS last_activity_at,
      ch.updated_at + p_minimum_inactive_for AS eligible_after
    FROM henvalt.shopify_checkout_identity_v2 ch
    JOIN henvalt.shopify_connections sc
      ON sc.id = ch.shopify_connection_id
     AND sc.tenant_id = ch.tenant_id
     AND sc.active IS TRUE
    JOIN henvalt.shopify_app_registry ar
      ON ar.app_key = sc.app_key
     AND ar.lifecycle_status = 'active'
    JOIN henvalt.tenants t
      ON t.id = ch.tenant_id
     AND t.status = 'ACTIVE'
    WHERE ch.checkout_status = 'OPEN'
      AND ch.shopify_checkout_token IS NOT NULL
      AND ch.updated_at <= pg_catalog.now() - p_minimum_inactive_for
      AND NOT EXISTS (
        SELECT 1
        FROM henvalt.shopify_order_identity_v2 o
        WHERE o.tenant_id = ch.tenant_id
          AND o.shopify_connection_id = ch.shopify_connection_id
          AND o.checkout_token = ch.shopify_checkout_token
      )
    ORDER BY ch.updated_at ASC
    LIMIT p_limit
  )
  INSERT INTO henvalt.shopify_checkout_recovery_candidate_v2 (
    tenant_id, shopify_connection_id, checkout_identity_id, checkout_token,
    source_delivery_id, last_activity_at, eligible_after, state, updated_at
  )
  SELECT
    e.tenant_id, e.shopify_connection_id, e.checkout_identity_id, e.checkout_token,
    e.source_delivery_id, e.last_activity_at, e.eligible_after,
    'READY_FOR_CONTACT_RESOLUTION', pg_catalog.now()
  FROM eligible e
  ON CONFLICT (shopify_connection_id, checkout_token)
  DO UPDATE SET
    checkout_identity_id = EXCLUDED.checkout_identity_id,
    source_delivery_id = EXCLUDED.source_delivery_id,
    last_activity_at = EXCLUDED.last_activity_at,
    eligible_after = EXCLUDED.eligible_after,
    state = CASE
      WHEN henvalt.shopify_checkout_recovery_candidate_v2.state = 'CONVERTED'
        THEN 'CONVERTED'
      ELSE 'READY_FOR_CONTACT_RESOLUTION'
    END,
    updated_at = pg_catalog.now();

  GET DIAGNOSTICS v_upserted = ROW_COUNT;

  RETURN jsonb_build_object(
    'accepted', true,
    'eligible_upserted', v_upserted,
    'converted_marked', v_converted,
    'closed_marked', v_closed,
    'delivery_authorized', false
  );
END;
$function$;

REVOKE ALL ON FUNCTION henvalt.refresh_shopify_checkout_recovery_candidates_v2(interval,integer)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION henvalt.refresh_shopify_checkout_recovery_candidates_v2(interval,integer)
  TO service_role;

COMMIT;

-- Revalidate the subscription and charge envelope at the last database boundary
-- before the worker sends appUsageRecordCreate to Shopify.
-- This serializes the authorization decision against cancellation and stale workers.
-- It cannot make a remote Shopify HTTP request atomic with a later cancellation.
BEGIN;

ALTER TABLE henvalt.billing_usage_charges
  ADD COLUMN IF NOT EXISTS egress_authorized_at timestamptz,
  ADD COLUMN IF NOT EXISTS egress_authorized_attempt integer;

CREATE OR REPLACE FUNCTION henvalt.control_plane_authorize_billing_usage_egress(
  p_shop_domain text,
  p_charge_id uuid,
  p_idempotency_key text,
  p_subscription_line_item_id text,
  p_amount numeric,
  p_currency text,
  p_attempt integer
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO pg_catalog, henvalt, pg_temp
AS $function$
DECLARE
  v_shop text := lower(btrim(coalesce(p_shop_domain, '')));
  v_tenant_id uuid;
  v_line_item text;
  v_test_mode boolean;
  v_active_shop_count integer;
  v_charge henvalt.billing_usage_charges%ROWTYPE;
  v_authorized_at timestamptz;
BEGIN
  IF v_shop !~ '^[a-z0-9][a-z0-9-]*[.]myshopify[.]com'
     OR v_shop <> (split_part(v_shop,'.',1) || '.myshopify.com')
     OR p_charge_id IS NULL
     OR length(coalesce(p_idempotency_key,'')) NOT BETWEEN 1 AND 255
     OR length(coalesce(p_subscription_line_item_id,'')) NOT BETWEEN 1 AND 255
     OR p_amount IS NULL OR p_amount <= 0
     OR p_currency !~ '^[A-Z]{3}
    RAISE EXCEPTION 'Invalid billing egress authorization envelope' USING ERRCODE = '22023';
  END IF;

  -- Match the claim path's lock order: shop -> tenant -> billing account -> charge.
  -- A cancellation committed before this check is therefore observed here.
  SELECT sc.tenant_id
    INTO v_tenant_id
    FROM henvalt.shopify_connections sc
   WHERE lower(sc.shop_domain) = v_shop
     AND sc.active IS TRUE
     AND sc.reauth_required_at IS NULL
   LIMIT 1
   FOR UPDATE OF sc;

  IF v_tenant_id IS NULL THEN
    RETURN jsonb_build_object('authorized', false, 'reason', 'SHOP_NOT_ACTIVE');
  END IF;

  PERFORM 1
    FROM henvalt.tenants t
   WHERE t.id = v_tenant_id
     AND t.status = 'ACTIVE'
   FOR UPDATE;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('authorized', false, 'reason', 'TENANT_NOT_ACTIVE');
  END IF;

  SELECT count(*)
    INTO v_active_shop_count
    FROM henvalt.shopify_connections sc
   WHERE sc.tenant_id = v_tenant_id
     AND sc.active IS TRUE;

  IF v_active_shop_count <> 1 THEN
    RETURN jsonb_build_object('authorized', false, 'reason', 'SINGLE_ACTIVE_SHOP_REQUIRED');
  END IF;

  SELECT ba.usage_line_item_id, ba.test_mode
    INTO v_line_item, v_test_mode
    FROM henvalt.billing_accounts ba
   WHERE ba.tenant_id = v_tenant_id
     AND ba.provider = 'SHOPIFY'
     AND ba.status = 'ACTIVE'
   FOR UPDATE;

  IF v_line_item IS NULL THEN
    RETURN jsonb_build_object('authorized', false, 'reason', 'BILLING_SUBSCRIPTION_NOT_ACTIVE');
  END IF;

  IF v_test_mode IS DISTINCT FROM TRUE THEN
    RETURN jsonb_build_object('authorized', false, 'reason', 'TEST_MODE_REQUIRED');
  END IF;

  IF v_line_item IS DISTINCT FROM p_subscription_line_item_id THEN
    RETURN jsonb_build_object('authorized', false, 'reason', 'SUBSCRIPTION_LINE_ITEM_CHANGED');
  END IF;

  SELECT buc.*
    INTO v_charge
    FROM henvalt.billing_usage_charges buc
   WHERE buc.id = p_charge_id
     AND buc.tenant_id = v_tenant_id
     AND buc.provider = 'SHOPIFY'
     AND buc.status = 'PENDING'
     AND buc.idempotency_key = p_idempotency_key
     AND buc.amount = p_amount
     AND buc.currency::text = p_currency
     AND buc.attempt_count = p_attempt
   FOR UPDATE;

  IF v_charge.id IS NULL THEN
    RETURN jsonb_build_object('authorized', false, 'reason', 'CHARGE_CLAIM_STALE');
  END IF;

  -- Persist a one-time point-of-no-return for this exact attempt. A repeat
  -- authorization of the same attempt is idempotent; a later attempt must pass
  -- the complete active-subscription checks again and receives a fresh marker.
  IF v_charge.egress_authorized_attempt IS DISTINCT FROM p_attempt THEN
    v_authorized_at := clock_timestamp();
    UPDATE henvalt.billing_usage_charges
       SET egress_authorized_at = v_authorized_at,
           egress_authorized_attempt = p_attempt,
           updated_at = v_authorized_at
     WHERE id = v_charge.id
       AND tenant_id = v_tenant_id;

    INSERT INTO henvalt.audit_log(
      tenant_id,event_name,entity_type,entity_id,actor_type,actor_reference,payload
    ) VALUES (
      v_tenant_id,'BILLING_USAGE_EGRESS_AUTHORIZED','BILLING_USAGE_CHARGE',
      v_charge.id,'SYSTEM','henvalt-shopify-usage-billing',
      jsonb_build_object(
        'attempt',p_attempt,
        'idempotencyKey',p_idempotency_key,
        'amount',v_charge.amount,
        'currency',v_charge.currency::text,
        'authorizedAt',v_authorized_at
      )
    );
  ELSE
    v_authorized_at := v_charge.egress_authorized_at;
  END IF;

  RETURN jsonb_build_object(
    'authorized', true,
    'chargeId', v_charge.id,
    'attempt', v_charge.attempt_count,
    'authorizedAt', v_authorized_at
  );
END;
$function$;

REVOKE ALL ON FUNCTION henvalt.control_plane_authorize_billing_usage_egress(text,uuid,text,text,numeric,text,integer)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION henvalt.control_plane_authorize_billing_usage_egress(text,uuid,text,text,integer)
  TO service_role;

COMMENT ON FUNCTION henvalt.control_plane_authorize_billing_usage_egress(text,uuid,text,text,integer) IS
  'Final test-subscription, active-shop and exact charge-envelope revalidation immediately before Shopify usage mutation. Persists the per-attempt authorization point-of-no-return; cancellation after authorization does not revoke an already-authorized in-flight request. Remote HTTP remains a separate system boundary.';

COMMIT;

     OR p_attempt IS NULL OR p_attempt < 1 OR p_attempt > 5 THEN
    RAISE EXCEPTION 'Invalid billing egress authorization envelope' USING ERRCODE = '22023';
  END IF;

  -- Match the claim path's lock order: shop -> tenant -> billing account -> charge.
  -- A cancellation committed before this check is therefore observed here.
  SELECT sc.tenant_id
    INTO v_tenant_id
    FROM henvalt.shopify_connections sc
   WHERE lower(sc.shop_domain) = v_shop
     AND sc.active IS TRUE
     AND sc.reauth_required_at IS NULL
   LIMIT 1
   FOR UPDATE OF sc;

  IF v_tenant_id IS NULL THEN
    RETURN jsonb_build_object('authorized', false, 'reason', 'SHOP_NOT_ACTIVE');
  END IF;

  PERFORM 1
    FROM henvalt.tenants t
   WHERE t.id = v_tenant_id
     AND t.status = 'ACTIVE'
   FOR UPDATE;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('authorized', false, 'reason', 'TENANT_NOT_ACTIVE');
  END IF;

  SELECT count(*)
    INTO v_active_shop_count
    FROM henvalt.shopify_connections sc
   WHERE sc.tenant_id = v_tenant_id
     AND sc.active IS TRUE;

  IF v_active_shop_count <> 1 THEN
    RETURN jsonb_build_object('authorized', false, 'reason', 'SINGLE_ACTIVE_SHOP_REQUIRED');
  END IF;

  SELECT ba.usage_line_item_id, ba.test_mode
    INTO v_line_item, v_test_mode
    FROM henvalt.billing_accounts ba
   WHERE ba.tenant_id = v_tenant_id
     AND ba.provider = 'SHOPIFY'
     AND ba.status = 'ACTIVE'
   FOR UPDATE;

  IF v_line_item IS NULL THEN
    RETURN jsonb_build_object('authorized', false, 'reason', 'BILLING_SUBSCRIPTION_NOT_ACTIVE');
  END IF;

  IF v_test_mode IS DISTINCT FROM TRUE THEN
    RETURN jsonb_build_object('authorized', false, 'reason', 'TEST_MODE_REQUIRED');
  END IF;

  IF v_line_item IS DISTINCT FROM p_subscription_line_item_id THEN
    RETURN jsonb_build_object('authorized', false, 'reason', 'SUBSCRIPTION_LINE_ITEM_CHANGED');
  END IF;

  SELECT buc.*
    INTO v_charge
    FROM henvalt.billing_usage_charges buc
   WHERE buc.id = p_charge_id
     AND buc.tenant_id = v_tenant_id
     AND buc.provider = 'SHOPIFY'
     AND buc.status = 'PENDING'
     AND buc.idempotency_key = p_idempotency_key
     AND buc.attempt_count = p_attempt
   FOR UPDATE;

  IF v_charge.id IS NULL THEN
    RETURN jsonb_build_object('authorized', false, 'reason', 'CHARGE_CLAIM_STALE');
  END IF;

  RETURN jsonb_build_object(
    'authorized', true,
    'chargeId', v_charge.id,
    'attempt', v_charge.attempt_count,
    'authorizedAt', clock_timestamp()
  );
END;
$function$;

REVOKE ALL ON FUNCTION henvalt.control_plane_authorize_billing_usage_egress(text,uuid,text,text,integer)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION henvalt.control_plane_authorize_billing_usage_egress(text,uuid,text,text,integer)
  TO service_role;

COMMENT ON FUNCTION henvalt.control_plane_authorize_billing_usage_egress(text,uuid,text,text,integer) IS
  'Final test-subscription, active-shop and current-charge revalidation immediately before Shopify usage mutation. Serializes against local cancellation; remote HTTP remains a separate system boundary.';

COMMIT;

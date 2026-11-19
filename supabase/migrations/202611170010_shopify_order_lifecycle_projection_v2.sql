-- HENVALT exact-store order lifecycle projection V2.
-- PREPARATION ONLY. Extends the verified order projection to order update,
-- paid and cancelled topics so current financial state remains synchronized.
-- Refunds remain a separate, unimplemented adjustment stream.

BEGIN;

ALTER TABLE henvalt.shopify_order_identity_v2
  ADD COLUMN IF NOT EXISTS source_updated_at timestamptz,
  ADD COLUMN IF NOT EXISTS last_refund_at timestamptz;

CREATE OR REPLACE FUNCTION henvalt.project_verified_shopify_order_v2(
  p_route_token text,
  p_delivery_id text,
  p_raw_body_base64 text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_route record;
  v_body bytea;
  v_payload jsonb;
  v_body_digest text;
  v_order_id text;
  v_checkout_token text;
  v_customer_reference text;
  v_customer_identity_id uuid;
  v_total_value numeric;
  v_currency text;
  v_financial_status text;
  v_ordered_at timestamptz;
  v_cancelled_at timestamptz;
  v_source_updated_at timestamptz;
  v_projection_status text := 'PROCESSED';
  v_match_status text := 'NO_CHECKOUT_TOKEN';
  v_order_identity_id uuid;
  v_updated integer := 0;
BEGIN
  IF p_route_token IS NULL OR length(p_route_token) < 40 OR length(p_route_token) > 128
     OR p_delivery_id IS NULL OR length(btrim(p_delivery_id)) = 0
     OR p_raw_body_base64 IS NULL OR length(p_raw_body_base64) > 2800000 THEN
    RETURN jsonb_build_object('accepted', false, 'status', 'REJECTED', 'code', 'INVALID_REQUEST');
  END IF;

  BEGIN
    v_body := pg_catalog.decode(p_raw_body_base64, 'base64');
    v_payload := pg_catalog.convert_from(v_body, 'UTF8')::jsonb;
  EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('accepted', false, 'status', 'REJECTED', 'code', 'INVALID_BODY');
  END;

  IF pg_catalog.octet_length(v_body) = 0 OR pg_catalog.octet_length(v_body) > 2097152 THEN
    RETURN jsonb_build_object('accepted', false, 'status', 'REJECTED', 'code', 'INVALID_BODY_SIZE');
  END IF;

  SELECT
    rt.tenant_id,
    rt.connection_id,
    rt.app_key,
    sc.shop_domain,
    sc.active AS connection_active,
    ar.lifecycle_status AS app_status,
    t.status::text AS tenant_status,
    d.id AS receipt_id,
    d.topic,
    d.raw_body_sha256
  INTO v_route
  FROM henvalt.shopify_webhook_route_tokens rt
  JOIN henvalt.shopify_connections sc
    ON sc.id = rt.connection_id AND sc.tenant_id = rt.tenant_id AND sc.app_key = rt.app_key
  JOIN henvalt.shopify_app_registry ar ON ar.app_key = rt.app_key
  JOIN henvalt.tenants t ON t.id = rt.tenant_id
  JOIN henvalt.shopify_webhook_deliveries d
    ON d.connection_id = rt.connection_id AND d.tenant_id = rt.tenant_id AND d.app_key = rt.app_key
  WHERE rt.token_hash = pg_catalog.encode(
          extensions.digest(pg_catalog.convert_to(p_route_token, 'UTF8'), 'sha256'), 'hex'
        )
    AND rt.revoked_at IS NULL
    AND (rt.expires_at IS NULL OR rt.expires_at > pg_catalog.now())
    AND d.shopify_delivery_id = p_delivery_id
  FOR UPDATE OF d;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('accepted', false, 'status', 'REJECTED', 'code', 'VERIFIED_RECEIPT_NOT_FOUND');
  END IF;

  IF v_route.connection_active IS DISTINCT FROM true
     OR v_route.app_status <> 'active'
     OR v_route.tenant_status <> 'ACTIVE' THEN
    RETURN jsonb_build_object('accepted', false, 'status', 'REJECTED', 'code', 'APP_CONNECTION_OR_TENANT_INACTIVE');
  END IF;

  IF v_route.topic NOT IN ('orders/create','orders/updated','orders/paid','orders/cancelled') THEN
    RETURN jsonb_build_object('accepted', false, 'status', 'REJECTED', 'code', 'UNSUPPORTED_ORDER_TOPIC');
  END IF;

  v_body_digest := pg_catalog.encode(extensions.digest(v_body, 'sha256'), 'hex');
  IF v_body_digest IS DISTINCT FROM v_route.raw_body_sha256 THEN
    RETURN jsonb_build_object('accepted', false, 'status', 'REJECTED', 'code', 'RECEIPT_BODY_MISMATCH');
  END IF;

  v_order_id := NULLIF(pg_catalog.btrim(v_payload->>'id'), '');
  IF v_order_id IS NULL OR length(v_order_id) > 200 THEN
    UPDATE henvalt.shopify_webhook_deliveries
       SET processing_status = 'REJECTED',
           failure_code = 'ORDER_ID_MISSING',
           metadata = COALESCE(metadata, '{}'::jsonb) || jsonb_build_object(
             'order_projection', 'REVIEW_REQUIRED',
             'order_projection_code', 'ORDER_ID_MISSING'
           )
     WHERE id = v_route.receipt_id;
    RETURN jsonb_build_object('accepted', true, 'status', 'REVIEW_REQUIRED', 'code', 'ORDER_ID_MISSING');
  END IF;

  v_checkout_token := NULLIF(pg_catalog.btrim(v_payload->>'checkout_token'), '');
  v_customer_reference := COALESCE(
    NULLIF(v_payload->'customer'->>'id', ''),
    NULLIF(v_payload->>'customer_id', '')
  );

  IF v_customer_reference IS NOT NULL
     AND length(v_customer_reference) BETWEEN 1 AND 200 THEN
    INSERT INTO henvalt.shopify_customer_identity_v2 (
      tenant_id, shopify_connection_id, external_customer_reference
    )
    VALUES (v_route.tenant_id, v_route.connection_id, v_customer_reference)
    ON CONFLICT (shopify_connection_id, external_customer_reference)
    DO UPDATE SET last_seen_at = GREATEST(
      henvalt.shopify_customer_identity_v2.last_seen_at, pg_catalog.now()
    )
    RETURNING id INTO v_customer_identity_id;
  END IF;

  IF (v_payload->>'total_price') ~ '^[0-9]{1,12}([.][0-9]{1,4})?$' THEN
    v_total_value := (v_payload->>'total_price')::numeric;
  END IF;

  v_currency := upper(NULLIF(v_payload->>'currency', ''));
  IF v_currency !~ '^[A-Z]{3}$' THEN v_currency := NULL; END IF;
  v_financial_status := NULLIF(lower(v_payload->>'financial_status'), '');

  BEGIN
    v_ordered_at := NULLIF(v_payload->>'created_at', '')::timestamptz;
  EXCEPTION WHEN OTHERS THEN
    v_ordered_at := NULL;
  END;
  BEGIN
    v_cancelled_at := NULLIF(v_payload->>'cancelled_at', '')::timestamptz;
  EXCEPTION WHEN OTHERS THEN
    v_cancelled_at := NULL;
  END;
  BEGIN
    v_source_updated_at := COALESCE(
      NULLIF(v_payload->>'updated_at', ''),
      NULLIF(v_payload->>'created_at', '')
    )::timestamptz;
  EXCEPTION WHEN OTHERS THEN
    v_source_updated_at := NULL;
  END;

  IF v_checkout_token IS NOT NULL THEN
    UPDATE henvalt.shopify_checkout_identity_v2
       SET checkout_status = 'COMPLETED',
           completed_at = COALESCE(completed_at, v_ordered_at, pg_catalog.now()),
           updated_at = pg_catalog.now()
     WHERE tenant_id = v_route.tenant_id
       AND shopify_connection_id = v_route.connection_id
       AND shopify_checkout_token = v_checkout_token;
    GET DIAGNOSTICS v_updated = ROW_COUNT;
    v_match_status := CASE WHEN v_updated > 0 THEN 'MATCHED' ELSE 'CHECKOUT_NOT_FOUND' END;
  END IF;

  INSERT INTO henvalt.shopify_order_identity_v2 (
    tenant_id, shopify_connection_id, shopify_order_id, checkout_token,
    customer_identity_id, total_value, currency, financial_status,
    ordered_at, cancelled_at, source_updated_at, source_delivery_id, checkout_match_status, updated_at
  )
  VALUES (
    v_route.tenant_id, v_route.connection_id, v_order_id, v_checkout_token,
    v_customer_identity_id, v_total_value, v_currency, v_financial_status,
    v_ordered_at, v_cancelled_at, v_source_updated_at, v_route.receipt_id, v_match_status, pg_catalog.now()
  )
  ON CONFLICT (shopify_connection_id, shopify_order_id)
  DO UPDATE SET
    checkout_token = COALESCE(EXCLUDED.checkout_token, henvalt.shopify_order_identity_v2.checkout_token),
    customer_identity_id = COALESCE(EXCLUDED.customer_identity_id, henvalt.shopify_order_identity_v2.customer_identity_id),
    total_value = COALESCE(EXCLUDED.total_value, henvalt.shopify_order_identity_v2.total_value),
    currency = COALESCE(EXCLUDED.currency, henvalt.shopify_order_identity_v2.currency),
    financial_status = COALESCE(EXCLUDED.financial_status, henvalt.shopify_order_identity_v2.financial_status),
    ordered_at = COALESCE(EXCLUDED.ordered_at, henvalt.shopify_order_identity_v2.ordered_at),
    cancelled_at = COALESCE(EXCLUDED.cancelled_at, henvalt.shopify_order_identity_v2.cancelled_at),
    source_delivery_id = EXCLUDED.source_delivery_id,
    checkout_match_status = CASE
      WHEN EXCLUDED.checkout_match_status = 'MATCHED' THEN 'MATCHED'
      ELSE henvalt.shopify_order_identity_v2.checkout_match_status
    END,
    source_updated_at = EXCLUDED.source_updated_at,
    updated_at = pg_catalog.now()
  WHERE
    (EXCLUDED.source_updated_at IS NULL
      AND henvalt.shopify_order_identity_v2.source_updated_at IS NULL
      AND henvalt.shopify_order_identity_v2.last_refund_at IS NULL)
    OR (EXCLUDED.source_updated_at IS NOT NULL
      AND EXCLUDED.source_updated_at >= GREATEST(
        COALESCE(henvalt.shopify_order_identity_v2.source_updated_at,'-infinity'::timestamptz),
        COALESCE(henvalt.shopify_order_identity_v2.last_refund_at,'-infinity'::timestamptz)
      ))
  RETURNING id INTO v_order_identity_id;

  IF v_order_identity_id IS NULL THEN
    SELECT id INTO v_order_identity_id
    FROM henvalt.shopify_order_identity_v2
    WHERE shopify_connection_id = v_route.connection_id
      AND shopify_order_id = v_order_id;
    v_projection_status := 'STALE_EVENT_IGNORED';
  END IF;

  UPDATE henvalt.shopify_webhook_deliveries
     SET processing_status = 'PROCESSED',
         processed_at = pg_catalog.now(),
         failure_code = NULL,
         metadata = COALESCE(metadata, '{}'::jsonb) || jsonb_build_object(
           'order_projection', v_projection_status,
           'checkout_match_status', v_match_status
         )
   WHERE id = v_route.receipt_id;

  RETURN jsonb_build_object(
    'accepted', true,
    'status', v_projection_status,
    'order_identity_id', v_order_identity_id,
    'checkout_match_status', v_match_status
  );
END;
$function$;

REVOKE ALL ON FUNCTION henvalt.project_verified_shopify_order_v2(text,text,text)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION henvalt.project_verified_shopify_order_v2(text,text,text)
  TO service_role;

COMMIT;

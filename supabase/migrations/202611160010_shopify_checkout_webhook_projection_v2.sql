-- HENVALT verified Shopify checkout projection V2.
-- PREPARATION ONLY. Depends on migrations 001, 002 and 009.
-- Shopify 2026-04 removed checkout.id from checkouts/create and update;
-- token is the stable checkout reference. This migration adds a token-first
-- projection from a receipt that has already passed app-specific raw-body HMAC.

BEGIN;

ALTER TABLE henvalt.shopify_checkout_identity_v2
  ALTER COLUMN shopify_checkout_id DROP NOT NULL;

ALTER TABLE henvalt.shopify_checkout_identity_v2
  ADD COLUMN IF NOT EXISTS shopify_checkout_token text,
  ADD COLUMN IF NOT EXISTS total_value numeric,
  ADD COLUMN IF NOT EXISTS currency text,
  ADD COLUMN IF NOT EXISTS completed_at timestamptz,
  ADD COLUMN IF NOT EXISTS source_updated_at timestamptz;

ALTER TABLE henvalt.shopify_checkout_identity_v2
  ADD CONSTRAINT shopify_checkout_identity_v2_token_nonempty
  CHECK (shopify_checkout_token IS NOT NULL
     AND length(btrim(shopify_checkout_token)) BETWEEN 1 AND 255);

DROP INDEX IF EXISTS henvalt.shopify_checkout_identity_v2_connection_token_uidx;
CREATE UNIQUE INDEX shopify_checkout_identity_v2_connection_token_uidx
  ON henvalt.shopify_checkout_identity_v2(shopify_connection_id, shopify_checkout_token);

CREATE OR REPLACE FUNCTION henvalt.project_verified_shopify_checkout_v2(
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
  v_token text;
  v_checkout_id text;
  v_customer_reference text;
  v_customer_identity_id uuid;
  v_total_value numeric;
  v_currency text;
  v_completed_at timestamptz;
  v_source_updated_at timestamptz;
  v_status text;
  v_inserted_id uuid;
  v_updated integer;
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
    d.id AS receipt_id,
    d.topic,
    d.raw_body_sha256,
    d.processing_status
  INTO v_route
  FROM henvalt.shopify_webhook_route_tokens rt
  JOIN henvalt.shopify_connections sc
    ON sc.id = rt.connection_id
   AND sc.tenant_id = rt.tenant_id
   AND sc.app_key = rt.app_key
  JOIN henvalt.shopify_app_registry ar
    ON ar.app_key = rt.app_key
  JOIN henvalt.shopify_webhook_deliveries d
    ON d.connection_id = rt.connection_id
   AND d.tenant_id = rt.tenant_id
   AND d.app_key = rt.app_key
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

  IF v_route.connection_active IS DISTINCT FROM true OR v_route.app_status <> 'active' THEN
    RETURN jsonb_build_object('accepted', false, 'status', 'REJECTED', 'code', 'APP_OR_CONNECTION_INACTIVE');
  END IF;

  IF v_route.topic NOT IN ('checkouts/create', 'checkouts/update') THEN
    RETURN jsonb_build_object('accepted', false, 'status', 'REJECTED', 'code', 'UNSUPPORTED_CHECKOUT_TOPIC');
  END IF;

  v_body_digest := pg_catalog.encode(extensions.digest(v_body, 'sha256'), 'hex');
  IF v_body_digest IS DISTINCT FROM v_route.raw_body_sha256 THEN
    RETURN jsonb_build_object('accepted', false, 'status', 'REJECTED', 'code', 'RECEIPT_BODY_MISMATCH');
  END IF;

  v_token := NULLIF(pg_catalog.btrim(v_payload->>'token'), '');
  IF v_token IS NULL OR length(v_token) > 255 THEN
    UPDATE henvalt.shopify_webhook_deliveries
       SET processing_status = 'REJECTED',
           failure_code = 'CHECKOUT_TOKEN_MISSING',
           metadata = COALESCE(metadata, '{}'::jsonb) || jsonb_build_object(
             'checkout_projection', 'REVIEW_REQUIRED',
             'checkout_projection_code', 'CHECKOUT_TOKEN_MISSING'
           )
     WHERE id = v_route.receipt_id;
    RETURN jsonb_build_object('accepted', true, 'status', 'REVIEW_REQUIRED', 'code', 'CHECKOUT_TOKEN_MISSING');
  END IF;

  v_checkout_id := NULLIF(pg_catalog.btrim(v_payload->>'id'), '');
  v_customer_reference := COALESCE(
    NULLIF(v_payload->'customer'->>'id', ''),
    NULLIF(v_payload->>'customer_id', '')
  );

  IF v_customer_reference IS NOT NULL
     AND length(v_customer_reference) BETWEEN 1 AND 200 THEN
    INSERT INTO henvalt.shopify_customer_identity_v2 (
      tenant_id, shopify_connection_id, external_customer_reference
    )
    VALUES (
      v_route.tenant_id, v_route.connection_id, v_customer_reference
    )
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
  IF v_currency !~ '^[A-Z]{3}$' THEN
    v_currency := NULL;
  END IF;

  BEGIN
    v_completed_at := NULLIF(v_payload->>'completed_at', '')::timestamptz;
  EXCEPTION WHEN OTHERS THEN
    v_completed_at := NULL;
  END;

  BEGIN
    v_source_updated_at := NULLIF(v_payload->>'updated_at', '')::timestamptz;
  EXCEPTION WHEN OTHERS THEN
    v_source_updated_at := NULL;
  END;

  v_status := CASE WHEN v_completed_at IS NOT NULL THEN 'COMPLETED' ELSE 'OPEN' END;

  INSERT INTO henvalt.shopify_checkout_identity_v2 (
    tenant_id,
    shopify_connection_id,
    shopify_checkout_id,
    shopify_checkout_token,
    total_value,
    currency,
    completed_at,
    source_updated_at,
    customer_identity_id,
    source_delivery_id,
    checkout_status,
    updated_at
  )
  VALUES (
    v_route.tenant_id,
    v_route.connection_id,
    v_checkout_id,
    v_token,
    v_total_value,
    v_currency,
    v_completed_at,
    v_source_updated_at,
    v_customer_identity_id,
    v_route.receipt_id,
    v_status,
    pg_catalog.now()
  )
  ON CONFLICT (shopify_connection_id, shopify_checkout_token)
  DO UPDATE SET
    shopify_checkout_id = COALESCE(EXCLUDED.shopify_checkout_id, henvalt.shopify_checkout_identity_v2.shopify_checkout_id),
    total_value = COALESCE(EXCLUDED.total_value, henvalt.shopify_checkout_identity_v2.total_value),
    currency = COALESCE(EXCLUDED.currency, henvalt.shopify_checkout_identity_v2.currency),
    completed_at = COALESCE(EXCLUDED.completed_at, henvalt.shopify_checkout_identity_v2.completed_at),
    customer_identity_id = COALESCE(EXCLUDED.customer_identity_id, henvalt.shopify_checkout_identity_v2.customer_identity_id),
    source_delivery_id = EXCLUDED.source_delivery_id,
    checkout_status = CASE
      WHEN EXCLUDED.checkout_status = 'COMPLETED' THEN 'COMPLETED'
      ELSE henvalt.shopify_checkout_identity_v2.checkout_status
    END,
    source_updated_at = EXCLUDED.source_updated_at,
    updated_at = pg_catalog.now()
  WHERE
    (EXCLUDED.source_updated_at IS NULL
      AND henvalt.shopify_checkout_identity_v2.source_updated_at IS NULL)
    OR (EXCLUDED.source_updated_at IS NOT NULL
      AND (henvalt.shopify_checkout_identity_v2.source_updated_at IS NULL
        OR EXCLUDED.source_updated_at >= henvalt.shopify_checkout_identity_v2.source_updated_at))
  RETURNING id INTO v_inserted_id;

  IF v_inserted_id IS NULL THEN
    SELECT id INTO v_inserted_id
    FROM henvalt.shopify_checkout_identity_v2
    WHERE shopify_connection_id = v_route.connection_id
      AND shopify_checkout_token = v_token;
    v_status := 'STALE_EVENT_IGNORED';
  END IF;

  UPDATE henvalt.shopify_webhook_deliveries
     SET processing_status = 'PROCESSED',
         processed_at = pg_catalog.now(),
         failure_code = NULL,
         metadata = COALESCE(metadata, '{}'::jsonb) || jsonb_build_object(
           'checkout_projection', v_status,
           'checkout_reference_type', 'token'
         )
   WHERE id = v_route.receipt_id;

  RETURN jsonb_build_object(
    'accepted', true,
    'status', v_status,
    'checkout_identity_id', v_inserted_id,
    'reference_type', 'token'
  );
END;
$function$;

REVOKE ALL ON FUNCTION henvalt.project_verified_shopify_checkout_v2(text,text,text)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION henvalt.project_verified_shopify_checkout_v2(text,text,text)
  TO service_role;

COMMIT;

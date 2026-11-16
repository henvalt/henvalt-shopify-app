-- HENVALT per-install Shopify webhook verification + durable receipt RPC.
-- PREPARATION ONLY: depends on 202611160001_shopify_webhook_identity_foundation.sql.
-- Do not apply until reviewed; no production systems are changed by this file.
--
-- The caller supplies the opaque route token, raw body and Shopify headers.
-- This function resolves the token, selects the app-specific Vault secret,
-- verifies the exact raw-body HMAC, checks the store header/body identity, and
-- persists the receipt atomically. It never returns secret material or IDs.

BEGIN;

CREATE OR REPLACE FUNCTION henvalt.accept_shopify_webhook_v2(
  p_route_token text,
  p_hmac_base64 text,
  p_raw_body_base64 text,
  p_shop_domain text,
  p_topic text,
  p_delivery_id text,
  p_event_id text DEFAULT NULL
)
RETURNS TABLE (
  accepted boolean,
  duplicate boolean,
  receipt_status text,
  rejection_code text
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'pg_catalog', 'henvalt', 'vault', 'extensions', 'pg_temp'
AS $function$
DECLARE
  v_route record;
  v_secret text;
  v_body bytea;
  v_expected bytea;
  v_provided bytea;
  v_payload jsonb;
  v_shop_id text;
  v_diff integer := 0;
  v_i integer;
  v_inserted uuid;
BEGIN
  accepted := false;
  duplicate := false;
  receipt_status := 'REJECTED';
  rejection_code := 'INVALID_REQUEST';

  IF NULLIF(p_route_token, '') IS NULL
     OR length(p_route_token) < 32
     OR NULLIF(p_hmac_base64, '') IS NULL
     OR NULLIF(p_raw_body_base64, '') IS NULL
     OR length(p_raw_body_base64) > 2800000
     OR NULLIF(p_shop_domain, '') IS NULL
     OR NULLIF(p_topic, '') IS NULL
     OR NULLIF(p_delivery_id, '') IS NULL THEN
    RETURN NEXT;
    RETURN;
  END IF;

  BEGIN
    v_body := decode(p_raw_body_base64, 'base64');
    v_payload := convert_from(v_body, 'UTF8')::jsonb;
    v_provided := decode(p_hmac_base64, 'base64');
  EXCEPTION WHEN OTHERS THEN
    RETURN NEXT;
    RETURN;
  END;

  IF octet_length(v_body) = 0 OR octet_length(v_body) > 2097152
     OR octet_length(v_provided) <> 32 THEN
    RETURN NEXT;
    RETURN;
  END IF;

  SELECT
    rt.id AS route_token_id,
    rt.tenant_id,
    rt.connection_id,
    rt.app_key,
    sc.shop_domain,
    sc.shopify_shop_id,
    sc.active AS connection_active,
    ar.webhook_secret_ref,
    ar.lifecycle_status AS app_status
  INTO v_route
  FROM henvalt.shopify_webhook_route_tokens rt
  JOIN henvalt.shopify_connections sc
    ON sc.id = rt.connection_id
   AND sc.tenant_id = rt.tenant_id
   AND sc.app_key = rt.app_key
  JOIN henvalt.shopify_app_registry ar
    ON ar.app_key = rt.app_key
  WHERE rt.token_hash = encode(extensions.digest(convert_to(p_route_token, 'UTF8'), 'sha256'), 'hex')
    AND rt.revoked_at IS NULL
    AND (rt.expires_at IS NULL OR rt.expires_at > now())
  FOR UPDATE OF rt;

  IF NOT FOUND THEN
    rejection_code := 'ROUTE_TOKEN_INVALID';
    RETURN NEXT;
    RETURN;
  END IF;

  IF v_route.connection_active IS DISTINCT FROM true
     OR v_route.app_status <> 'active' THEN
    rejection_code := 'APP_OR_CONNECTION_INACTIVE';
    RETURN NEXT;
    RETURN;
  END IF;

  IF lower(p_shop_domain) <> v_route.shop_domain
     OR p_shop_domain <> lower(p_shop_domain) THEN
    rejection_code := 'SHOP_DOMAIN_MISMATCH';
    RETURN NEXT;
    RETURN;
  END IF;

  -- Shopify resource webhook bodies commonly include shop_id. When present,
  -- it must match the connection's immutable shop ID; absence is permitted
  -- because some topic payloads do not include it.
  v_shop_id := COALESCE(v_payload->>'shop_id', v_payload->>'shopId');
  IF v_shop_id IS NOT NULL
     AND v_route.shopify_shop_id IS NOT NULL
     AND v_shop_id <> v_route.shopify_shop_id THEN
    rejection_code := 'SHOP_ID_MISMATCH';
    RETURN NEXT;
    RETURN;
  END IF;

  SELECT ds.decrypted_secret
    INTO v_secret
  FROM vault.decrypted_secrets ds
  WHERE ds.name = v_route.webhook_secret_ref
  LIMIT 1;

  IF v_secret IS NULL OR v_secret = '' THEN
    rejection_code := 'APP_SECRET_NOT_CONFIGURED';
    RETURN NEXT;
    RETURN;
  END IF;

  v_expected := extensions.hmac(v_body, convert_to(v_secret, 'UTF8'), 'sha256');
  FOR v_i IN 0..31 LOOP
    v_diff := v_diff | (get_byte(v_expected, v_i) # get_byte(v_provided, v_i));
  END LOOP;

  IF v_diff <> 0 THEN
    rejection_code := 'HMAC_INVALID';
    RETURN NEXT;
    RETURN;
  END IF;

  INSERT INTO henvalt.shopify_webhook_deliveries (
    tenant_id,
    connection_id,
    app_key,
    shopify_delivery_id,
    shopify_event_id,
    topic,
    shop_domain_header,
    raw_body_sha256,
    hmac_verified_at,
    processing_status,
    metadata
  )
  VALUES (
    v_route.tenant_id,
    v_route.connection_id,
    v_route.app_key,
    p_delivery_id,
    NULLIF(p_event_id, ''),
    p_topic,
    p_shop_domain,
    encode(extensions.digest(v_body, 'sha256'), 'hex'),
    now(),
    'RECEIVED',
    jsonb_build_object('ingress_version', 'v2')
  )
  ON CONFLICT (connection_id, shopify_delivery_id) DO NOTHING
  RETURNING id INTO v_inserted;

  UPDATE henvalt.shopify_webhook_route_tokens
     SET last_used_at = now()
   WHERE id = v_route.route_token_id;

  IF v_inserted IS NULL THEN
    accepted := true;
    duplicate := true;
    receipt_status := 'DUPLICATE';
    rejection_code := NULL;
    RETURN NEXT;
    RETURN;
  END IF;

  accepted := true;
  duplicate := false;
  receipt_status := 'RECEIVED';
  rejection_code := NULL;
  RETURN NEXT;
END;
$function$;

REVOKE ALL ON FUNCTION henvalt.accept_shopify_webhook_v2(text,text,text,text,text,text,text)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION henvalt.accept_shopify_webhook_v2(text,text,text,text,text,text,text)
  TO service_role;

COMMIT;

-- V2 exact-store checkout jurisdiction projection.
-- PREPARATION ONLY. Reads country codes from the same verified checkout receipt;
-- persists only ISO alpha-2 country code, never address/name/postcode.
BEGIN;

CREATE OR REPLACE FUNCTION henvalt.project_verified_shopify_checkout_jurisdiction_v2(
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
  v_digest text;
  v_token text;
  v_country text;
  v_updated integer := 0;
BEGIN
  IF p_route_token IS NULL OR length(p_route_token)<40 OR length(p_route_token)>128
     OR p_delivery_id IS NULL OR length(btrim(p_delivery_id))=0
     OR p_raw_body_base64 IS NULL OR length(p_raw_body_base64)>2800000 THEN
    RETURN jsonb_build_object('accepted',false,'code','INVALID_REQUEST');
  END IF;
  BEGIN
    v_body:=pg_catalog.decode(p_raw_body_base64,'base64');
    v_payload:=pg_catalog.convert_from(v_body,'UTF8')::jsonb;
  EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('accepted',false,'code','INVALID_BODY');
  END;
  IF pg_catalog.octet_length(v_body)=0 OR pg_catalog.octet_length(v_body)>2097152 THEN
    RETURN jsonb_build_object('accepted',false,'code','INVALID_BODY_SIZE');
  END IF;

  SELECT rt.connection_id,rt.tenant_id,rt.app_key,
         sc.active AS connection_active,ar.lifecycle_status AS app_status,
         d.id AS receipt_id,d.topic,d.raw_body_sha256
    INTO v_route
  FROM henvalt.shopify_webhook_route_tokens rt
  JOIN henvalt.shopify_connections sc
    ON sc.id=rt.connection_id AND sc.tenant_id=rt.tenant_id AND sc.app_key=rt.app_key
  JOIN henvalt.shopify_app_registry ar ON ar.app_key=rt.app_key
  JOIN henvalt.shopify_webhook_deliveries d
    ON d.connection_id=rt.connection_id AND d.tenant_id=rt.tenant_id AND d.app_key=rt.app_key
  WHERE rt.token_hash=pg_catalog.encode(extensions.digest(pg_catalog.convert_to(p_route_token,'UTF8'),'sha256'),'hex')
    AND rt.revoked_at IS NULL
    AND (rt.expires_at IS NULL OR rt.expires_at>pg_catalog.now())
    AND d.shopify_delivery_id=p_delivery_id
  FOR UPDATE OF d;

  IF NOT FOUND THEN RETURN jsonb_build_object('accepted',false,'code','VERIFIED_RECEIPT_NOT_FOUND'); END IF;
  IF v_route.topic NOT IN ('checkouts/create','checkouts/update') THEN
    RETURN jsonb_build_object('accepted',false,'code','UNSUPPORTED_CHECKOUT_TOPIC');
  END IF;
  IF v_route.connection_active IS DISTINCT FROM true OR v_route.app_status<>'active' THEN
    RETURN jsonb_build_object('accepted',false,'code','APP_OR_CONNECTION_INACTIVE');
  END IF;
  v_digest:=pg_catalog.encode(extensions.digest(v_body,'sha256'),'hex');
  IF v_digest IS DISTINCT FROM v_route.raw_body_sha256 THEN
    RETURN jsonb_build_object('accepted',false,'code','RECEIPT_BODY_MISMATCH');
  END IF;

  v_token:=NULLIF(pg_catalog.btrim(v_payload->>'token'),'');
  IF v_token IS NULL THEN RETURN jsonb_build_object('accepted',false,'code','CHECKOUT_TOKEN_MISSING'); END IF;

  v_country:=upper(COALESCE(
    NULLIF(v_payload->'shipping_address'->>'country_code',''),
    NULLIF(v_payload->'billing_address'->>'country_code','')
  ));
  IF v_country !~ '^[A-Z]{2}$' THEN v_country:=NULL; END IF;

  IF v_country IS NOT NULL THEN
    UPDATE henvalt.shopify_checkout_identity_v2
       SET jurisdiction_country_code=v_country,updated_at=pg_catalog.now()
     WHERE tenant_id=v_route.tenant_id
       AND shopify_connection_id=v_route.connection_id
       AND shopify_checkout_token=v_token;
    GET DIAGNOSTICS v_updated=ROW_COUNT;
    IF v_updated=0 THEN
      RETURN jsonb_build_object('accepted',false,'code','CHECKOUT_IDENTITY_NOT_FOUND');
    END IF;
  END IF;

  RETURN jsonb_build_object('accepted',true,'status','PROJECTED',
    'jurisdiction_country_code',v_country,
    'jurisdiction_known',v_country IS NOT NULL,
    'address_fields_stored',false);
END;
$function$;

REVOKE ALL ON FUNCTION henvalt.project_verified_shopify_checkout_jurisdiction_v2(text,text,text)
  FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION henvalt.project_verified_shopify_checkout_jurisdiction_v2(text,text,text)
  TO service_role;

COMMIT;

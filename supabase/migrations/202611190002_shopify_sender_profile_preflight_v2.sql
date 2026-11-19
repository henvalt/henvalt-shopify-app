-- HENVALT exact-store verified sender preflight V2.
-- PREPARATION ONLY. Exposes sender identity to trusted Edge Functions only.
BEGIN;

CREATE OR REPLACE FUNCTION henvalt.resolve_shopify_sender_profile_for_delivery_v2(
  p_sender_profile_id uuid,
  p_shopify_connection_id uuid,
  p_provider_account_key text
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=''
AS $function$
DECLARE
  v_from_email text;
  v_from_name text;
BEGIN
  IF current_setting('request.jwt.claim.role',true) IS DISTINCT FROM 'service_role' THEN
    RAISE EXCEPTION 'service_role_required' USING ERRCODE='42501';
  END IF;

  IF p_sender_profile_id IS NULL
     OR p_shopify_connection_id IS NULL
     OR p_provider_account_key IS NULL
     OR length(btrim(p_provider_account_key)) NOT BETWEEN 24 AND 96 THEN
    RETURN jsonb_build_object('ready',false,'code','INVALID_SENDER_CONTEXT_REQUEST');
  END IF;

  SELECT sp.from_email,sp.from_name
    INTO v_from_email,v_from_name
  FROM henvalt.shopify_sender_profiles_v2 sp
  JOIN henvalt.shopify_connections sc
    ON sc.id=sp.shopify_connection_id
   AND sc.tenant_id=sp.tenant_id
  JOIN henvalt.shopify_app_registry ar
    ON ar.app_key=sc.app_key
   AND ar.lifecycle_status='active'
  JOIN henvalt.tenants t
    ON t.id=sp.tenant_id
   AND t.status='ACTIVE'
  JOIN henvalt.shopify_mailer_provider_registry_v2 pr
    ON pr.tenant_id=sp.tenant_id
   AND pr.provider_account_key=sp.provider_account_key
   AND pr.status='ACTIVE'
  WHERE sp.id=p_sender_profile_id
    AND sp.shopify_connection_id=p_shopify_connection_id
    AND sp.provider_account_key=p_provider_account_key
    AND sp.status='ACTIVE'
    AND sp.verified_at IS NOT NULL
    AND sc.active IS TRUE;

  IF v_from_email IS NULL OR v_from_name IS NULL
     OR length(btrim(v_from_name))=0 THEN
    RETURN jsonb_build_object('ready',false,'code','VERIFIED_SENDER_NOT_READY');
  END IF;

  RETURN jsonb_build_object(
    'ready',true,
    'from_email',v_from_email,
    'from_name',v_from_name,
    'sender_pii_scope','BUSINESS_SENDER_ONLY',
    'recipient_pii_returned',false,
    'delivery_authorized',false
  );
END;
$function$;

REVOKE ALL ON FUNCTION henvalt.resolve_shopify_sender_profile_for_delivery_v2(uuid,uuid,text)
  FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION henvalt.resolve_shopify_sender_profile_for_delivery_v2(uuid,uuid,text)
  TO service_role;

COMMIT;

-- HENVALT exact-store pixel delivery context resolver V2.
-- Returns only short-lived server secrets and routing metadata to a trusted Edge Function.
-- It never returns shopper email, creates a permit, reserves cost, or calls a provider.
BEGIN;

CREATE OR REPLACE FUNCTION henvalt.resolve_shopify_pixel_delivery_context_v2(
  p_opportunity_id uuid
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=''
AS $function$
DECLARE
  v record;
  v_assessment jsonb;
  v_shopify_token text;
  v_provider_token text;
  v_fingerprint_secret text;
  v_customer_gid text;
BEGIN
  IF current_setting('request.jwt.claim.role',true) IS DISTINCT FROM 'service_role' THEN
    RAISE EXCEPTION 'service_role_required' USING ERRCODE='42501';
  END IF;
  IF p_opportunity_id IS NULL THEN
    RETURN jsonb_build_object('ready',false,'code','OPPORTUNITY_REQUIRED');
  END IF;

  v_assessment:=henvalt.assess_shopify_pixel_delivery_eligibility_v2(p_opportunity_id);
  IF coalesce((v_assessment->>'eligible')::boolean,false) IS NOT TRUE THEN
    RETURN jsonb_build_object('ready',false,'code',coalesce(v_assessment->>'code','PIXEL_NOT_ELIGIBLE'));
  END IF;

  SELECT
    o.id AS opportunity_id,o.tenant_id,o.shopify_connection_id,o.customer_identity_id,
    o.app_key,ci.external_customer_reference,sc.shop_domain,sc.access_token_secret_ref,
    pr.provider_account_key,pr.api_token_secret_ref,pr.recipient_fingerprint_secret_ref,
    sp.id AS sender_profile_id,sp.from_email,sp.from_name,
    v_assessment->>'policy_version' AS policy_version
  INTO v
  FROM henvalt.shopify_recovery_opportunity_v2 o
  JOIN henvalt.shopify_customer_identity_v2 ci
    ON ci.id=o.customer_identity_id AND ci.tenant_id=o.tenant_id
   AND ci.shopify_connection_id=o.shopify_connection_id
  JOIN henvalt.shopify_connections sc
    ON sc.id=o.shopify_connection_id AND sc.tenant_id=o.tenant_id
  JOIN henvalt.shopify_app_registry ar ON ar.app_key=o.app_key
  JOIN henvalt.tenants t ON t.id=o.tenant_id
  JOIN henvalt.shopify_mailer_provider_registry_v2 pr
    ON pr.tenant_id=o.tenant_id AND pr.status='ACTIVE'
  JOIN henvalt.shopify_sender_profiles_v2 sp
    ON sp.tenant_id=o.tenant_id AND sp.shopify_connection_id=o.shopify_connection_id
   AND sp.provider_account_key=pr.provider_account_key
   AND sp.status='ACTIVE' AND sp.verified_at IS NOT NULL
  JOIN henvalt.billing_accounts ba ON ba.tenant_id=o.tenant_id
  WHERE o.id=p_opportunity_id
    AND sc.active IS TRUE AND ar.lifecycle_status='active'
    AND t.status::text='ACTIVE'
    AND pr.api_token_secret_ref IS NOT NULL
    AND pr.recipient_fingerprint_secret_ref IS NOT NULL
    AND ba.status='ACTIVE' AND ba.test_mode IS FALSE
    AND ba.henvalt_percentage>0 AND ba.usage_cap_amount>0
    AND ba.monthly_email_limit>0
    AND pr.email_unit_cost_amount>0
    AND pr.email_unit_cost_currency=pg_catalog.upper(pg_catalog.btrim(ba.currency::text))
  ORDER BY pr.created_at,sp.created_at
  LIMIT 1
  FOR SHARE OF sc,pr,sp,ba;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ready',false,'code','PIXEL_PROVIDER_SENDER_OR_BILLING_CONTEXT_MISSING');
  END IF;

  IF v.shop_domain !~ '^[a-z0-9][a-z0-9-]*[.]myshopify[.]com$'
     OR v.access_token_secret_ref IS NULL
     OR v.access_token_secret_ref !~* '^[0-9a-f-]{36}$' THEN
    RETURN jsonb_build_object('ready',false,'code','SHOPIFY_TOKEN_REFERENCE_INVALID');
  END IF;

  v_customer_gid:=CASE
    WHEN v.external_customer_reference LIKE 'gid://shopify/Customer/%'
      THEN v.external_customer_reference
    WHEN v.external_customer_reference ~ '^[0-9]{1,30}$'
      THEN 'gid://shopify/Customer/'||v.external_customer_reference
    ELSE NULL END;
  IF v_customer_gid IS NULL THEN
    RETURN jsonb_build_object('ready',false,'code','SHOPIFY_CUSTOMER_REFERENCE_INVALID');
  END IF;

  SELECT ds.decrypted_secret INTO v_shopify_token
  FROM vault.decrypted_secrets ds
  WHERE ds.id=v.access_token_secret_ref::uuid;
  SELECT ds.decrypted_secret INTO v_provider_token
  FROM vault.decrypted_secrets ds
  WHERE ds.name=v.api_token_secret_ref OR ds.id::text=v.api_token_secret_ref
  LIMIT 1;
  SELECT ds.decrypted_secret INTO v_fingerprint_secret
  FROM vault.decrypted_secrets ds
  WHERE ds.name=v.recipient_fingerprint_secret_ref
     OR ds.id::text=v.recipient_fingerprint_secret_ref
  LIMIT 1;

  IF v_shopify_token IS NULL OR length(v_shopify_token)<20
     OR v_provider_token IS NULL OR length(v_provider_token)<20
     OR v_fingerprint_secret IS NULL OR length(v_fingerprint_secret)<32 THEN
    RETURN jsonb_build_object('ready',false,'code','PIXEL_DELIVERY_SECRET_UNAVAILABLE');
  END IF;

  RETURN jsonb_build_object(
    'ready',true,'opportunity_id',v.opportunity_id,
    'tenant_id',v.tenant_id,'shopify_connection_id',v.shopify_connection_id,
    'customer_identity_id',v.customer_identity_id,'shop_domain',v.shop_domain,
    'customer_gid',v_customer_gid,'shopify_access_token',v_shopify_token,
    'provider_account_key',v.provider_account_key,'mailer_send_api_token',v_provider_token,
    'recipient_fingerprint_secret',v_fingerprint_secret,
    'sender_profile_id',v.sender_profile_id,'from_email',v.from_email,
    'from_name',v.from_name,'policy_version',v.policy_version,
    'recipient_email_returned',false,'permit_issued',false,
    'send_attempt_created',false,'provider_cost_reserved',false,
    'provider_submission_performed',false
  );
END;
$function$;

REVOKE ALL ON FUNCTION henvalt.resolve_shopify_pixel_delivery_context_v2(uuid)
  FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION henvalt.resolve_shopify_pixel_delivery_context_v2(uuid)
  TO service_role;

COMMIT;

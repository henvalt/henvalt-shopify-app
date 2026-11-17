-- HENVALT trusted contact resolution and provider submission boundary V2.
-- PREPARATION ONLY. Depends on candidate migrations 001-017.

BEGIN;

ALTER TABLE henvalt.shopify_mailer_provider_registry_v2
  ADD COLUMN IF NOT EXISTS api_token_secret_ref text;

CREATE OR REPLACE FUNCTION henvalt.resolve_shopify_delivery_context_v2(p_intervention_id uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $function$
DECLARE v_row record; v_access_token text; v_api_token text; v_fingerprint_secret text;
BEGIN
  IF p_intervention_id IS NULL THEN RETURN jsonb_build_object('ready',false,'code','INTERVENTION_REQUIRED'); END IF;
  SELECT i.id AS intervention_id,i.tenant_id,i.shopify_connection_id,i.customer_identity_id,
    i.status AS intervention_status,opp.status AS opportunity_status,opp.app_key,opp.candidate_id,
    opp.checkout_identity_id,opp.customer_identity_id AS opportunity_customer_id,
    c.state AS candidate_state,c.checkout_token,c.checkout_identity_id AS candidate_checkout_id,
    ch.checkout_status,ch.jurisdiction_country_code,ch.shopify_checkout_token,
    ch.customer_identity_id AS checkout_customer_id,ci.external_customer_reference,
    sc.shop_domain,sc.shopify_shop_id,sc.access_token_secret_ref,sc.access_token_expires_at,
    sc.token_type,sc.reauth_required_at,sc.scopes,sc.active AS connection_active,sc.app_key AS connection_app_key,
    ar.shopify_client_id,ar.lifecycle_status AS app_status,t.status::text AS tenant_status,
    consent.marketing_state,consent.consent_updated_at,pr.provider_account_key,pr.status AS provider_status,
    pr.api_token_secret_ref,pr.recipient_fingerprint_secret_ref,
    sp.id AS sender_profile_id,sp.status AS sender_status,sp.verified_at,
    ba.status AS billing_status,ba.test_mode,ba.henvalt_percentage,ba.usage_cap_amount,ba.monthly_email_limit
  INTO v_row
  FROM henvalt.shopify_recovery_intervention_v2 i
  JOIN henvalt.shopify_recovery_opportunity_v2 opp ON opp.id=i.opportunity_id AND opp.tenant_id=i.tenant_id AND opp.shopify_connection_id=i.shopify_connection_id
  JOIN henvalt.shopify_checkout_recovery_candidate_v2 c ON c.id=opp.candidate_id AND c.tenant_id=i.tenant_id AND c.shopify_connection_id=i.shopify_connection_id
  JOIN henvalt.shopify_checkout_identity_v2 ch ON ch.id=opp.checkout_identity_id AND ch.tenant_id=i.tenant_id AND ch.shopify_connection_id=i.shopify_connection_id
  JOIN henvalt.shopify_customer_identity_v2 ci ON ci.id=i.customer_identity_id AND ci.tenant_id=i.tenant_id AND ci.shopify_connection_id=i.shopify_connection_id
  JOIN henvalt.shopify_connections sc ON sc.id=i.shopify_connection_id AND sc.tenant_id=i.tenant_id
  JOIN henvalt.shopify_app_registry ar ON ar.app_key=opp.app_key
  JOIN henvalt.tenants t ON t.id=i.tenant_id
  JOIN henvalt.shopify_customer_email_consent_v2 consent ON consent.customer_identity_id=i.customer_identity_id AND consent.tenant_id=i.tenant_id AND consent.shopify_connection_id=i.shopify_connection_id
  JOIN henvalt.shopify_mailer_provider_registry_v2 pr ON pr.tenant_id=i.tenant_id
  JOIN henvalt.shopify_sender_profiles_v2 sp ON sp.tenant_id=i.tenant_id AND sp.shopify_connection_id=i.shopify_connection_id AND sp.provider_account_key=pr.provider_account_key
  JOIN henvalt.billing_accounts ba ON ba.tenant_id=i.tenant_id
  WHERE i.id=p_intervention_id AND i.status='READY_FOR_AUTHORIZATION'
  ORDER BY pr.created_at,sp.created_at LIMIT 1;

  IF NOT FOUND THEN RETURN jsonb_build_object('ready',false,'code','DELIVERY_CONTEXT_NOT_FOUND'); END IF;
  IF v_row.opportunity_status<>'CONTACT_RESOLUTION_PENDING' OR v_row.candidate_state<>'READY_FOR_CONTACT_RESOLUTION'
     OR v_row.opportunity_customer_id IS DISTINCT FROM v_row.customer_identity_id
     OR v_row.checkout_customer_id IS DISTINCT FROM v_row.customer_identity_id
     OR v_row.candidate_checkout_id IS DISTINCT FROM v_row.checkout_identity_id
    THEN RETURN jsonb_build_object('ready',false,'code','RECOVERY_CHAIN_NOT_ELIGIBLE'); END IF;
  IF v_row.connection_active IS DISTINCT FROM true OR v_row.app_status<>'active'
     OR v_row.connection_app_key IS DISTINCT FROM v_row.app_key OR v_row.tenant_status<>'ACTIVE'
    THEN RETURN jsonb_build_object('ready',false,'code','APP_STORE_OR_TENANT_INACTIVE'); END IF;
  IF v_row.shop_domain !~ '^[a-z0-9][a-z0-9-]*[.]myshopify[.]com$' OR v_row.token_type<>'offline_expiring'
     OR v_row.reauth_required_at IS NOT NULL OR coalesce('read_customers'=ANY(v_row.scopes),false) IS NOT TRUE
    THEN RETURN jsonb_build_object('ready',false,'code','SHOPIFY_CUSTOMER_ACCESS_UNAVAILABLE'); END IF;
  IF v_row.checkout_status<>'OPEN' OR v_row.shopify_checkout_token IS DISTINCT FROM v_row.checkout_token
     OR v_row.jurisdiction_country_code IS NULL
     OR v_row.jurisdiction_country_code NOT IN ('GB','US','CA','AU')
    THEN RETURN jsonb_build_object('ready',false,'code','CHECKOUT_OR_JURISDICTION_INELIGIBLE'); END IF;
  IF EXISTS(SELECT 1 FROM henvalt.shopify_order_identity_v2 o WHERE o.tenant_id=v_row.tenant_id AND o.shopify_connection_id=v_row.shopify_connection_id AND o.checkout_token=v_row.checkout_token)
    THEN RETURN jsonb_build_object('ready',false,'code','SAME_STORE_ORDER_EXISTS'); END IF;
  IF v_row.marketing_state<>'SUBSCRIBED' OR v_row.consent_updated_at IS NULL
    THEN RETURN jsonb_build_object('ready',false,'code','CURRENT_EMAIL_CONSENT_REQUIRED'); END IF;
  IF EXISTS(SELECT 1 FROM henvalt.shopify_delivery_suppressions_v2 s WHERE s.tenant_id=v_row.tenant_id AND s.shopify_connection_id=v_row.shopify_connection_id AND s.customer_identity_id=v_row.customer_identity_id AND s.active IS TRUE)
    THEN RETURN jsonb_build_object('ready',false,'code','RECIPIENT_SUPPRESSED'); END IF;
  IF v_row.provider_status<>'ACTIVE' OR v_row.api_token_secret_ref IS NULL OR v_row.recipient_fingerprint_secret_ref IS NULL
     OR v_row.sender_status<>'ACTIVE' OR v_row.verified_at IS NULL
     OR v_row.billing_status<>'ACTIVE' OR v_row.test_mode IS DISTINCT FROM false
     OR v_row.henvalt_percentage IS NULL OR v_row.henvalt_percentage<=0
     OR v_row.usage_cap_amount IS NULL OR v_row.usage_cap_amount<=0
     OR v_row.monthly_email_limit IS NULL OR v_row.monthly_email_limit<=0
    THEN RETURN jsonb_build_object('ready',false,'code','BILLING_PROVIDER_OR_SENDER_NOT_READY'); END IF;
  IF v_row.access_token_expires_at IS NULL OR v_row.access_token_expires_at<=pg_catalog.now()+interval '2 minutes'
    THEN RETURN jsonb_build_object('ready',false,'code','SHOPIFY_TOKEN_REFRESH_REQUIRED','shop_domain',v_row.shop_domain,'shopify_client_id',v_row.shopify_client_id); END IF;

  -- Monetary provider-cost reservation is not implemented yet. Keep this boundary closed.
  RETURN jsonb_build_object('ready',false,'code','MONETARY_USAGE_RESERVATION_REQUIRED');

  SELECT ds.decrypted_secret INTO v_access_token FROM vault.decrypted_secrets ds WHERE ds.id=v_row.access_token_secret_ref::uuid;
  SELECT ds.decrypted_secret INTO v_api_token FROM vault.decrypted_secrets ds WHERE ds.name=v_row.api_token_secret_ref OR ds.id::text=v_row.api_token_secret_ref LIMIT 1;
  SELECT ds.decrypted_secret INTO v_fingerprint_secret FROM vault.decrypted_secrets ds WHERE ds.name=v_row.recipient_fingerprint_secret_ref OR ds.id::text=v_row.recipient_fingerprint_secret_ref LIMIT 1;
  IF v_access_token IS NULL OR v_access_token='' OR v_api_token IS NULL OR v_api_token=''
     OR v_fingerprint_secret IS NULL OR length(v_fingerprint_secret)<32
    THEN RETURN jsonb_build_object('ready',false,'code','DELIVERY_SECRET_UNAVAILABLE'); END IF;

  RETURN jsonb_build_object('ready',true,'intervention_id',v_row.intervention_id,'tenant_id',v_row.tenant_id,
    'shopify_connection_id',v_row.shopify_connection_id,'customer_identity_id',v_row.customer_identity_id,
    'external_customer_reference',v_row.external_customer_reference,'shop_domain',v_row.shop_domain,
    'shopify_shop_id',v_row.shopify_shop_id,'shopify_client_id',v_row.shopify_client_id,
    'access_token',v_access_token,'provider_account_key',v_row.provider_account_key,
    'mailer_send_api_token',v_api_token,'recipient_fingerprint_secret',v_fingerprint_secret,
    'sender_profile_id',v_row.sender_profile_id);
END;
$function$;

CREATE OR REPLACE FUNCTION henvalt.record_shopify_delivery_submission_v2(
  p_send_attempt_id uuid,p_outcome text,p_provider_message_id text DEFAULT NULL
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $function$
DECLARE v_attempt henvalt.shopify_recovery_send_attempt_v2%ROWTYPE;
BEGIN
  IF p_send_attempt_id IS NULL OR p_outcome NOT IN ('SUBMITTED','FAILED','AMBIGUOUS')
    THEN RETURN jsonb_build_object('recorded',false,'code','INVALID_REQUEST'); END IF;
  IF p_outcome='SUBMITTED' AND (p_provider_message_id IS NULL OR p_provider_message_id !~ '^[A-Za-z0-9_-]{10,100}$')
    THEN RETURN jsonb_build_object('recorded',false,'code','PROVIDER_MESSAGE_ID_REQUIRED'); END IF;
  SELECT * INTO v_attempt FROM henvalt.shopify_recovery_send_attempt_v2 WHERE id=p_send_attempt_id FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('recorded',false,'code','SEND_ATTEMPT_NOT_FOUND'); END IF;
  IF v_attempt.status<>'AUTHORIZED' THEN RETURN jsonb_build_object('recorded',false,'code','SEND_ATTEMPT_ALREADY_FINALIZED'); END IF;
  UPDATE henvalt.shopify_recovery_send_attempt_v2 SET status=p_outcome,
    provider_message_id=CASE WHEN p_outcome='SUBMITTED' THEN p_provider_message_id ELSE NULL END,
    submitted_at=CASE WHEN p_outcome='SUBMITTED' THEN pg_catalog.now() ELSE NULL END,
    updated_at=pg_catalog.now() WHERE id=p_send_attempt_id AND status='AUTHORIZED';
  UPDATE henvalt.shopify_recovery_intervention_v2 SET status=p_outcome,updated_at=pg_catalog.now()
    WHERE id=v_attempt.intervention_id AND tenant_id=v_attempt.tenant_id
      AND shopify_connection_id=v_attempt.shopify_connection_id AND status='AUTHORIZED';
  RETURN jsonb_build_object('recorded',true,'status',p_outcome);
END;
$function$;

REVOKE ALL ON FUNCTION henvalt.resolve_shopify_delivery_context_v2(uuid) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION henvalt.record_shopify_delivery_submission_v2(uuid,text,text) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION henvalt.resolve_shopify_delivery_context_v2(uuid) TO service_role;
GRANT EXECUTE ON FUNCTION henvalt.record_shopify_delivery_submission_v2(uuid,text,text) TO service_role;

COMMIT;

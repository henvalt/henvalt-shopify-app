-- HENVALT final checkout provider-submission authorization V2.
-- Rechecks exact-store, app, tenant, checkout, consent, suppression, sender and cost state
-- after permit consumption and immediately before the MailerSend request.
BEGIN;

CREATE OR REPLACE FUNCTION henvalt.authorize_shopify_delivery_provider_submission_v2(
  p_send_attempt_id uuid,
  p_recipient_fingerprint_hex text
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_attempt record;
BEGIN
  IF current_setting('request.jwt.claim.role',true) IS DISTINCT FROM 'service_role' THEN
    RAISE EXCEPTION 'service_role_required' USING ERRCODE='42501';
  END IF;
  IF p_send_attempt_id IS NULL OR p_recipient_fingerprint_hex IS NULL
    OR p_recipient_fingerprint_hex !~ '^[0-9a-fA-F]{64}$' THEN
    RETURN jsonb_build_object('authorized',false,'code','INVALID_REQUEST');
  END IF;

  SELECT
    a.id,a.tenant_id,a.shopify_connection_id,a.customer_identity_id,
    a.intervention_id,a.status AS attempt_status,
    permit_row.recipient_fingerprint,permit_row.consumed_at,permit_row.expires_at,
    reservation_row.status AS reservation_status,
    i.status AS intervention_status,i.opportunity_id,
    opp.status AS opportunity_status,opp.app_key,opp.candidate_id,
    opp.checkout_identity_id,opp.customer_identity_id AS opportunity_customer_id,
    c.state AS candidate_state,c.checkout_token,
    ch.checkout_status,ch.jurisdiction_country_code,ch.shopify_checkout_token,
    ch.customer_identity_id AS checkout_customer_id,
    consent.marketing_state,consent.consent_updated_at,
    sc.active AS connection_active,sc.app_key AS connection_app_key,
    ar.lifecycle_status AS app_status,t.status::text AS tenant_status,
    pr.status AS provider_status,sp.status AS sender_status,sp.verified_at,
    ba.status AS billing_status,ba.test_mode,ba.henvalt_percentage,
    ba.usage_cap_amount,ba.monthly_email_limit
  INTO v_attempt
  FROM henvalt.shopify_recovery_send_attempt_v2 a
  JOIN henvalt.shopify_delivery_permits_v2 permit_row
    ON permit_row.send_attempt_id=a.id
   AND permit_row.tenant_id=a.tenant_id
   AND permit_row.shopify_connection_id=a.shopify_connection_id
  JOIN henvalt.shopify_delivery_cost_reservations_v2 reservation_row
    ON reservation_row.send_attempt_id=a.id
   AND reservation_row.tenant_id=a.tenant_id
   AND reservation_row.shopify_connection_id=a.shopify_connection_id
  JOIN henvalt.shopify_recovery_intervention_v2 i
    ON i.id=a.intervention_id AND i.tenant_id=a.tenant_id
   AND i.shopify_connection_id=a.shopify_connection_id
   AND i.customer_identity_id=a.customer_identity_id
  JOIN henvalt.shopify_recovery_opportunity_v2 opp
    ON opp.id=i.opportunity_id AND opp.tenant_id=i.tenant_id
   AND opp.shopify_connection_id=i.shopify_connection_id
  JOIN henvalt.shopify_checkout_recovery_candidate_v2 c
    ON c.id=opp.candidate_id AND c.tenant_id=opp.tenant_id
   AND c.shopify_connection_id=opp.shopify_connection_id
  JOIN henvalt.shopify_checkout_identity_v2 ch
    ON ch.id=opp.checkout_identity_id AND ch.tenant_id=opp.tenant_id
   AND ch.shopify_connection_id=opp.shopify_connection_id
  JOIN henvalt.shopify_customer_email_consent_v2 consent
    ON consent.customer_identity_id=a.customer_identity_id
   AND consent.tenant_id=a.tenant_id
   AND consent.shopify_connection_id=a.shopify_connection_id
  JOIN henvalt.shopify_connections sc
    ON sc.id=a.shopify_connection_id AND sc.tenant_id=a.tenant_id
  JOIN henvalt.shopify_app_registry ar ON ar.app_key=opp.app_key
  JOIN henvalt.tenants t ON t.id=a.tenant_id
  JOIN henvalt.shopify_mailer_provider_registry_v2 pr
    ON pr.provider_account_key=a.provider_account_key AND pr.tenant_id=a.tenant_id
  JOIN henvalt.shopify_sender_profiles_v2 sp
    ON sp.id=permit_row.sender_profile_id AND sp.tenant_id=a.tenant_id
   AND sp.shopify_connection_id=a.shopify_connection_id
   AND sp.provider_account_key=a.provider_account_key
  JOIN henvalt.billing_accounts ba ON ba.tenant_id=a.tenant_id
  WHERE a.id=p_send_attempt_id
  FOR UPDATE OF a,permit_row,reservation_row,i,opp,c,ch,consent,sc,ar,t,pr,sp,ba;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('authorized',false,'code','CHECKOUT_ATTEMPT_OR_PERMIT_NOT_FOUND');
  END IF;
  IF v_attempt.attempt_status<>'AUTHORIZED'
    OR v_attempt.intervention_status<>'AUTHORIZED'
    OR v_attempt.reservation_status<>'RESERVED'
    OR v_attempt.consumed_at IS NULL
    OR v_attempt.expires_at<=pg_catalog.now() THEN
    RETURN jsonb_build_object('authorized',false,'code','CHECKOUT_ATTEMPT_NOT_SENDABLE');
  END IF;
  IF v_attempt.recipient_fingerprint<>pg_catalog.decode(p_recipient_fingerprint_hex,'hex') THEN
    RETURN jsonb_build_object('authorized',false,'code','RECIPIENT_FINGERPRINT_CHANGED');
  END IF;
  IF v_attempt.connection_active IS DISTINCT FROM true
    OR v_attempt.app_status<>'active'
    OR v_attempt.connection_app_key IS DISTINCT FROM v_attempt.app_key
    OR v_attempt.tenant_status<>'ACTIVE'
    OR v_attempt.candidate_state<>'READY_FOR_CONTACT_RESOLUTION' THEN
    RETURN jsonb_build_object('authorized',false,'code','APP_STORE_OR_TENANT_INACTIVE');
  END IF;
  IF v_attempt.opportunity_status<>'CONTACT_RESOLUTION_PENDING'
    OR v_attempt.opportunity_customer_id IS DISTINCT FROM v_attempt.customer_identity_id
    OR v_attempt.checkout_customer_id IS DISTINCT FROM v_attempt.customer_identity_id
    OR v_attempt.checkout_status<>'OPEN'
    OR v_attempt.shopify_checkout_token IS DISTINCT FROM v_attempt.checkout_token
    OR v_attempt.jurisdiction_country_code NOT IN ('GB','US','CA','AU') THEN
    RETURN jsonb_build_object('authorized',false,'code','CHECKOUT_OR_JURISDICTION_INELIGIBLE');
  END IF;
  IF v_attempt.marketing_state<>'SUBSCRIBED'
    OR v_attempt.consent_updated_at IS NULL THEN
    RETURN jsonb_build_object('authorized',false,'code','CURRENT_EMAIL_CONSENT_REQUIRED');
  END IF;
  IF EXISTS (
    SELECT 1 FROM henvalt.shopify_order_identity_v2 o
    WHERE o.tenant_id=v_attempt.tenant_id
      AND o.shopify_connection_id=v_attempt.shopify_connection_id
      AND o.checkout_token=v_attempt.checkout_token
  ) OR EXISTS (
    SELECT 1 FROM henvalt.shopify_delivery_suppressions_v2 s
    WHERE s.tenant_id=v_attempt.tenant_id
      AND s.shopify_connection_id=v_attempt.shopify_connection_id
      AND s.active IS TRUE
      AND (s.customer_identity_id=v_attempt.customer_identity_id
        OR s.recipient_fingerprint= v_attempt.recipient_fingerprint)
  ) OR EXISTS (
    SELECT 1 FROM henvalt.shopify_customer_redaction_guards_v2 g
    WHERE g.tenant_id=v_attempt.tenant_id
      AND g.shopify_connection_id=v_attempt.shopify_connection_id
      AND g.customer_identity_id=v_attempt.customer_identity_id
      AND g.state IN ('ACTIVE','REVIEW_REQUIRED')
  ) THEN
    RETURN jsonb_build_object('authorized',false,'code','ORDER_SUPPRESSION_OR_PRIVACY_GUARD_CHANGED');
  END IF;
  IF v_attempt.provider_status<>'ACTIVE'
    OR v_attempt.sender_status<>'ACTIVE'
    OR v_attempt.verified_at IS NULL
    OR v_attempt.billing_status<>'ACTIVE'
    OR v_attempt.test_mode IS DISTINCT FROM false
    OR v_attempt.henvalt_percentage IS NULL OR v_attempt.henvalt_percentage<=0
    OR v_attempt.usage_cap_amount IS NULL OR v_attempt.usage_cap_amount<=0
    OR v_attempt.monthly_email_limit IS NULL OR v_attempt.monthly_email_limit<=0 THEN
    RETURN jsonb_build_object('authorized',false,'code','BILLING_PROVIDER_OR_SENDER_NOT_READY');
  END IF;

  RETURN jsonb_build_object(
    'authorized',true,
    'send_attempt_id',v_attempt.id,
    'intervention_id',v_attempt.intervention_id,
    'provider_cost_reserved',true,
    'recipient_email_returned',false,
    'provider_submission_performed',false
  );
END;
$function$;

REVOKE ALL ON FUNCTION henvalt.authorize_shopify_delivery_provider_submission_v2(uuid,text)
  FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION henvalt.authorize_shopify_delivery_provider_submission_v2(uuid,text)
  TO service_role;

COMMIT;

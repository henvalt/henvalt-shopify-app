-- HENVALT final pixel provider-submission authorization V2.
-- Called after the second live Shopify customer/consent lookup and immediately before MailerSend.
-- This narrows, but cannot eliminate, the cross-system consent-change race.
BEGIN;

CREATE OR REPLACE FUNCTION henvalt.authorize_shopify_pixel_provider_submission_v2(
 p_send_attempt_id uuid,
 p_recipient_fingerprint_hex text
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=''
AS $function$
DECLARE
 a record;
 assessment jsonb;
BEGIN
 IF current_setting('request.jwt.claim.role',true) IS DISTINCT FROM 'service_role' THEN
  RAISE EXCEPTION 'service_role_required' USING ERRCODE='42501';
 END IF;
 IF p_send_attempt_id IS NULL OR p_recipient_fingerprint_hex IS NULL
   OR p_recipient_fingerprint_hex !~ '^[0-9a-fA-F]{64}$' THEN
  RETURN jsonb_build_object('authorized',false,'code','INVALID_REQUEST');
 END IF;

 SELECT a.id,a.tenant_id,a.shopify_connection_id,a.opportunity_id,
        a.customer_identity_id,a.status,a.provider_account_key,
        p.recipient_fingerprint,p.consumed_at,p.expires_at,
        r.status AS reservation_status,r.amount,r.currency
 INTO a
 FROM henvalt.shopify_pixel_send_attempts_v2 a
 JOIN henvalt.shopify_pixel_delivery_permits_v2 p
   ON p.pixel_send_attempt_id=a.id AND p.tenant_id=a.tenant_id
  AND p.shopify_connection_id=a.shopify_connection_id
 JOIN henvalt.shopify_pixel_delivery_cost_reservations_v2 r
   ON r.pixel_send_attempt_id=a.id AND r.tenant_id=a.tenant_id
  AND r.shopify_connection_id=a.shopify_connection_id
 WHERE a.id=p_send_attempt_id
 FOR UPDATE OF a,p,r;
 IF NOT FOUND THEN
  RETURN jsonb_build_object('authorized',false,'code','PIXEL_ATTEMPT_OR_RESERVATION_NOT_FOUND');
 END IF;
 IF a.status<>'AUTHORIZED' OR a.reservation_status<>'RESERVED'
   OR a.consumed_at IS NULL OR a.expires_at<=pg_catalog.now() THEN
  RETURN jsonb_build_object('authorized',false,'code','PIXEL_ATTEMPT_NOT_SENDABLE');
 END IF;
 IF a.recipient_fingerprint<>pg_catalog.decode(p_recipient_fingerprint_hex,'hex') THEN
  RETURN jsonb_build_object('authorized',false,'code','RECIPIENT_FINGERPRINT_CHANGED');
 END IF;
 IF EXISTS (
  SELECT 1 FROM henvalt.shopify_delivery_suppressions_v2 s
  WHERE s.tenant_id=a.tenant_id AND s.shopify_connection_id=a.shopify_connection_id
   AND s.active IS TRUE
   AND (s.customer_identity_id=a.customer_identity_id
     OR s.recipient_fingerprint=a.recipient_fingerprint)
 ) THEN
  RETURN jsonb_build_object('authorized',false,'code','RECIPIENT_SUPPRESSION_CHANGED');
 END IF;

 assessment:=henvalt.assess_shopify_pixel_delivery_eligibility_v2(a.opportunity_id);
 IF coalesce((assessment->>'eligible')::boolean,false) IS NOT TRUE THEN
  RETURN jsonb_build_object('authorized',false,
   'code',coalesce(assessment->>'code','PIXEL_ELIGIBILITY_CHANGED'));
 END IF;

 RETURN jsonb_build_object('authorized',true,'send_attempt_id',a.id,
  'opportunity_id',a.opportunity_id,'provider_account_key',a.provider_account_key,
  'provider_cost_reserved',true,'recipient_email_returned',false,
  'provider_submission_performed',false,
  'consent_checked_in_current_request',true);
END;
$function$;

REVOKE ALL ON FUNCTION henvalt.authorize_shopify_pixel_provider_submission_v2(uuid,text)
 FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION henvalt.authorize_shopify_pixel_provider_submission_v2(uuid,text)
 TO service_role;
COMMIT;

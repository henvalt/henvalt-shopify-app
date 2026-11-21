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
 v_attempt record;
 assessment jsonb;
BEGIN
 IF current_setting('request.jwt.claim.role',true) IS DISTINCT FROM 'service_role' THEN
  RAISE EXCEPTION 'service_role_required' USING ERRCODE='42501';
 END IF;
 IF p_send_attempt_id IS NULL OR p_recipient_fingerprint_hex IS NULL
   OR p_recipient_fingerprint_hex !~ '^[0-9a-fA-F]{64}$' THEN
  RETURN jsonb_build_object('authorized',false,'code','INVALID_REQUEST');
 END IF;

 SELECT attempt_row.id,attempt_row.tenant_id,attempt_row.shopify_connection_id,attempt_row.opportunity_id,
        attempt_row.customer_identity_id,attempt_row.status,attempt_row.provider_account_key,
        permit_row.recipient_fingerprint,permit_row.consumed_at,permit_row.expires_at,
        reservation_row.status AS reservation_status,reservation_row.amount,reservation_row.currency
 INTO v_attempt
 FROM henvalt.shopify_pixel_send_attempts_v2 attempt_row
 JOIN henvalt.shopify_pixel_delivery_permits_v2 permit_row
   ON permit_row.pixel_send_attempt_id=attempt_row.id AND permit_row.tenant_id=attempt_row.tenant_id
  AND permit_row.shopify_connection_id=attempt_row.shopify_connection_id
 JOIN henvalt.shopify_pixel_delivery_cost_reservations_v2 reservation_row
   ON reservation_row.pixel_send_attempt_id=attempt_row.id AND reservation_row.tenant_id=attempt_row.tenant_id
  AND reservation_row.shopify_connection_id=attempt_row.shopify_connection_id
 WHERE attempt_row.id=p_send_attempt_id
 FOR UPDATE OF attempt_row,permit_row,reservation_row;
 IF NOT FOUND THEN
  RETURN jsonb_build_object('authorized',false,'code','PIXEL_ATTEMPT_OR_RESERVATION_NOT_FOUND');
 END IF;
 IF v_attempt.status<>'AUTHORIZED' OR v_attempt.reservation_status<>'RESERVED'
   OR v_attempt.consumed_at IS NULL OR v_attempt.expires_at<=pg_catalog.now() THEN
  RETURN jsonb_build_object('authorized',false,'code','PIXEL_ATTEMPT_NOT_SENDABLE');
 END IF;
 IF v_attempt.recipient_fingerprint<>pg_catalog.decode(p_recipient_fingerprint_hex,'hex') THEN
  RETURN jsonb_build_object('authorized',false,'code','RECIPIENT_FINGERPRINT_CHANGED');
 END IF;
 IF EXISTS (
  SELECT 1 FROM henvalt.shopify_delivery_suppressions_v2 s
  WHERE s.tenant_id=v_attempt.tenant_id AND s.shopify_connection_id=v_attempt.shopify_connection_id
   AND s.active IS TRUE
   AND (s.customer_identity_id=v_attempt.customer_identity_id
     OR s.recipient_fingerprint=v_attempt.recipient_fingerprint)
 ) THEN
  RETURN jsonb_build_object('authorized',false,'code','RECIPIENT_SUPPRESSION_CHANGED');
 END IF;

 assessment:=henvalt.assess_shopify_pixel_delivery_eligibility_v2(v_attempt.opportunity_id);
 IF coalesce((assessment->>'eligible')::boolean,false) IS NOT TRUE THEN
  RETURN jsonb_build_object('authorized',false,
   'code',coalesce(assessment->>'code','PIXEL_ELIGIBILITY_CHANGED'));
 END IF;

 RETURN jsonb_build_object('authorized',true,'send_attempt_id',v_attempt.id,
  'opportunity_id',v_attempt.opportunity_id,'provider_account_key',v_attempt.provider_account_key,
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

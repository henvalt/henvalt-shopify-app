-- HENVALT strict pixel provider outcome reconciliation V2.
-- A send can be marked SUBMITTED only with a provider message reference.
-- AMBIGUOUS is never converted to FAILED: provider acceptance may already have happened.
BEGIN;
CREATE OR REPLACE FUNCTION henvalt.record_shopify_pixel_send_attempt_result_v2(
 p_send_attempt_id uuid,p_status text,p_provider_message_reference text DEFAULT NULL
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=''
AS $function$
DECLARE v_attempt record;
BEGIN
 IF current_setting('request.jwt.claim.role',true) IS DISTINCT FROM 'service_role' THEN
  RAISE EXCEPTION 'service_role_required' USING ERRCODE='42501';
 END IF;
 IF p_send_attempt_id IS NULL OR p_status IS NULL
   OR p_status NOT IN ('SUBMITTED','FAILED','AMBIGUOUS')
   OR (p_provider_message_reference IS NOT NULL AND length(p_provider_message_reference)>240)
   OR (p_status='SUBMITTED' AND (p_provider_message_reference IS NULL OR pg_catalog.btrim(p_provider_message_reference)=''))
   OR (p_status<>'SUBMITTED' AND p_provider_message_reference IS NOT NULL) THEN
  RETURN jsonb_build_object('recorded',false,'code','INVALID_RESULT');
 END IF;
 SELECT * INTO v_attempt
 FROM henvalt.shopify_pixel_send_attempts_v2
 WHERE id=p_send_attempt_id FOR UPDATE;
 IF NOT FOUND THEN
  RETURN jsonb_build_object('recorded',false,'code','ATTEMPT_NOT_FOUND');
 END IF;
 IF v_attempt.status NOT IN ('AUTHORIZED','AMBIGUOUS')
   OR (v_attempt.status='AMBIGUOUS' AND p_status<>'SUBMITTED') THEN
  RETURN jsonb_build_object('recorded',false,'code','ATTEMPT_ALREADY_FINALIZED');
 END IF;
 UPDATE henvalt.shopify_pixel_send_attempts_v2
 SET status=p_status,
     provider_message_reference=CASE WHEN p_status='SUBMITTED' THEN p_provider_message_reference ELSE NULL END,
     updated_at=pg_catalog.now()
 WHERE id=v_attempt.id;
 RETURN jsonb_build_object('recorded',true,'status',p_status,
  'provider_cost_state',CASE WHEN p_status='SUBMITTED' THEN 'SETTLED'
    WHEN p_status='FAILED' THEN 'RELEASED' ELSE 'RESERVED' END);
END;
$function$;
REVOKE ALL ON FUNCTION henvalt.record_shopify_pixel_send_attempt_result_v2(uuid,text,text)
 FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION henvalt.record_shopify_pixel_send_attempt_result_v2(uuid,text,text)
 TO service_role;
COMMIT;

-- HENVALT MailerSend signed-event reconciliation for pixel attempts V2.
-- A verified provider activity event is authoritative evidence that MailerSend accepted the message.
-- Raw payloads and recipient PII remain outside the database.
BEGIN;

ALTER TABLE henvalt.shopify_mailer_provider_events_v2
 ADD COLUMN IF NOT EXISTS pixel_send_attempt_id uuid;

CREATE UNIQUE INDEX IF NOT EXISTS shopify_pixel_send_attempt_provider_message_uidx
 ON henvalt.shopify_pixel_send_attempts_v2(provider_account_key,provider_message_reference)
 WHERE provider_message_reference IS NOT NULL;

ALTER TABLE henvalt.shopify_mailer_provider_events_v2
 ADD CONSTRAINT shopify_mailer_provider_events_pixel_attempt_fkey
 FOREIGN KEY(pixel_send_attempt_id,tenant_id,shopify_connection_id)
 REFERENCES henvalt.shopify_pixel_send_attempts_v2(id,tenant_id,shopify_connection_id)
 ON UPDATE RESTRICT ON DELETE RESTRICT;

CREATE UNIQUE INDEX IF NOT EXISTS shopify_pixel_send_attempts_id_tenant_connection_uidx
 ON henvalt.shopify_pixel_send_attempts_v2(id,tenant_id,shopify_connection_id);

CREATE OR REPLACE FUNCTION henvalt.reconcile_mailersend_pixel_provider_event_v2(
 p_provider_account_key text,p_provider_event_id text
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=''
AS $function$
DECLARE v_event record; v_attempt record; v_result jsonb;
BEGIN
 IF current_setting('request.jwt.claim.role',true) IS DISTINCT FROM 'service_role' THEN
  RAISE EXCEPTION 'service_role_required' USING ERRCODE='42501';
 END IF;
 IF p_provider_account_key IS NULL OR p_provider_event_id IS NULL
   OR length(p_provider_event_id)>160 THEN
  RETURN jsonb_build_object('accepted',false,'code','INVALID_REQUEST');
 END IF;
 SELECT id,provider_account_key,provider_message_id,event_type,processing_status,
        pixel_send_attempt_id,body_sha256
 INTO v_event
 FROM henvalt.shopify_mailer_provider_events_v2
 WHERE provider_account_key=p_provider_account_key AND provider_event_id=p_provider_event_id
 FOR UPDATE;
 IF NOT FOUND THEN RETURN jsonb_build_object('accepted',false,'code','VERIFIED_EVENT_NOT_FOUND'); END IF;
 IF v_event.pixel_send_attempt_id IS NOT NULL THEN
  RETURN jsonb_build_object('accepted',true,'status','DUPLICATE','pixel_attempt_reconciled',true);
 END IF;
 IF v_event.processing_status<>'UNMATCHED' OR v_event.provider_message_id IS NULL
   OR v_event.event_type NOT IN ('activity.sent','activity.delivered','activity.soft_bounced',
      'activity.hard_bounced','activity.unsubscribed','activity.spam_complaint',
      'activity.opened','activity.clicked') THEN
  RETURN jsonb_build_object('accepted',true,'status','NOT_PIXEL_RECONCILABLE','pixel_attempt_reconciled',false);
 END IF;
 SELECT id,tenant_id,shopify_connection_id,status,provider_message_reference
 INTO v_attempt
 FROM henvalt.shopify_pixel_send_attempts_v2
 WHERE provider_account_key=p_provider_account_key
   AND provider_message_reference=v_event.provider_message_id
 FOR UPDATE;
 IF NOT FOUND THEN
  RETURN jsonb_build_object('accepted',true,'status','UNMATCHED','pixel_attempt_reconciled',false);
 END IF;
 IF v_attempt.status='AMBIGUOUS' THEN
  v_result:=henvalt.record_shopify_pixel_send_attempt_result_v2(
   v_attempt.id,'SUBMITTED',v_event.provider_message_id
  );
  IF coalesce((v_result->>'recorded')::boolean,false) IS NOT TRUE THEN
   RETURN jsonb_build_object('accepted',false,'code','PIXEL_OUTCOME_RECONCILIATION_REJECTED');
  END IF;
 ELSIF v_attempt.status<>'SUBMITTED' THEN
  RETURN jsonb_build_object('accepted',true,'status','PIXEL_ATTEMPT_NOT_RECONCILIABLE','pixel_attempt_reconciled',false);
 END IF;
 UPDATE henvalt.shopify_mailer_provider_events_v2
 SET tenant_id=v_attempt.tenant_id,shopify_connection_id=v_attempt.shopify_connection_id,
     pixel_send_attempt_id=v_attempt.id,processing_status='PROCESSED'
 WHERE id=v_event.id AND processing_status='UNMATCHED' AND pixel_send_attempt_id IS NULL;
 IF NOT FOUND THEN
  RETURN jsonb_build_object('accepted',false,'code','PIXEL_EVENT_CLAIM_RACE');
 END IF;
 RETURN jsonb_build_object('accepted',true,'status','PROCESSED',
  'pixel_attempt_reconciled',true,'provider_cost_state','SETTLED','recipient_pii_stored',false);
END;
$function$;

REVOKE ALL ON FUNCTION henvalt.reconcile_mailersend_pixel_provider_event_v2(text,text)
 FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION henvalt.reconcile_mailersend_pixel_provider_event_v2(text,text)
 TO service_role;
COMMIT;

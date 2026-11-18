-- HENVALT MailerSend signed-event reconciliation for pixel attempts V2.
-- A verified provider activity event is authoritative evidence that MailerSend accepted the message.
-- Raw payloads and recipient PII remain outside the database.
BEGIN;

ALTER TABLE henvalt.shopify_mailer_provider_events_v2
 ADD COLUMN IF NOT EXISTS pixel_send_attempt_id uuid;

ALTER TABLE henvalt.shopify_delivery_suppressions_v2
 ALTER COLUMN source_send_attempt_id DROP NOT NULL,
 ADD COLUMN source_pixel_send_attempt_id uuid,
 ADD CONSTRAINT shopify_delivery_suppressions_v2_pixel_attempt_fkey
  FOREIGN KEY(source_pixel_send_attempt_id,tenant_id,shopify_connection_id)
  REFERENCES henvalt.shopify_pixel_send_attempts_v2(id,tenant_id,shopify_connection_id)
  ON UPDATE RESTRICT ON DELETE RESTRICT,
 ADD CONSTRAINT shopify_delivery_suppressions_v2_one_attempt_source_check
  CHECK ((source_send_attempt_id IS NULL) <> (source_pixel_send_attempt_id IS NULL));

CREATE UNIQUE INDEX IF NOT EXISTS shopify_pixel_send_attempt_provider_message_uidx
 ON henvalt.shopify_pixel_send_attempts_v2(provider_account_key,provider_message_reference)
 WHERE provider_message_reference IS NOT NULL;

CREATE UNIQUE INDEX IF NOT EXISTS shopify_pixel_send_attempts_id_tenant_connection_uidx
 ON henvalt.shopify_pixel_send_attempts_v2(id,tenant_id,shopify_connection_id);

ALTER TABLE henvalt.shopify_mailer_provider_events_v2
 ADD CONSTRAINT shopify_mailer_provider_events_pixel_attempt_fkey
 FOREIGN KEY(pixel_send_attempt_id,tenant_id,shopify_connection_id)
 REFERENCES henvalt.shopify_pixel_send_attempts_v2(id,tenant_id,shopify_connection_id)
 ON UPDATE RESTRICT ON DELETE RESTRICT;

CREATE OR REPLACE FUNCTION henvalt.reconcile_mailersend_pixel_provider_event_v2(
 p_provider_account_key text,p_provider_event_id text
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=''
AS $function$
DECLARE v_event record; v_attempt record; v_result jsonb;
 v_suppression_type text; v_fingerprint bytea;
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
 SELECT id,tenant_id,shopify_connection_id,customer_identity_id,status,provider_message_reference
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

 v_suppression_type:=CASE v_event.event_type
  WHEN 'activity.unsubscribed' THEN 'UNSUBSCRIBED'
  WHEN 'activity.spam_complaint' THEN 'SPAM_COMPLAINT'
  WHEN 'activity.hard_bounced' THEN 'HARD_BOUNCE'
  ELSE NULL END;
 IF v_suppression_type IS NOT NULL THEN
  SELECT p.recipient_fingerprint INTO v_fingerprint
  FROM henvalt.shopify_pixel_delivery_permits_v2 p
  WHERE p.pixel_send_attempt_id=v_attempt.id
    AND p.tenant_id=v_attempt.tenant_id
    AND p.shopify_connection_id=v_attempt.shopify_connection_id;
  INSERT INTO henvalt.shopify_delivery_suppressions_v2(
   tenant_id,shopify_connection_id,customer_identity_id,recipient_fingerprint,
   suppression_type,source_send_attempt_id,source_pixel_send_attempt_id,source_provider_event_id
  ) VALUES(
   v_attempt.tenant_id,v_attempt.shopify_connection_id,v_attempt.customer_identity_id,
   v_fingerprint,v_suppression_type,NULL,v_attempt.id,v_event.id
  ) ON CONFLICT(shopify_connection_id,customer_identity_id,suppression_type,source_provider_event_id)
   DO NOTHING;
 END IF;
 RETURN jsonb_build_object('accepted',true,'status','PROCESSED',
  'pixel_attempt_reconciled',true,'provider_cost_state','SETTLED',
  'suppression_applied',v_suppression_type IS NOT NULL,'recipient_pii_stored',false);
END;
$function$;

REVOKE ALL ON FUNCTION henvalt.reconcile_mailersend_pixel_provider_event_v2(text,text)
 FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION henvalt.reconcile_mailersend_pixel_provider_event_v2(text,text)
 TO service_role;

-- Retain a provider message reference on AMBIGUOUS outcomes when MailerSend returned
-- one but the durable SUBMITTED write could not be confirmed. This enables signed-event reconciliation.
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
   OR (p_status='FAILED' AND p_provider_message_reference IS NOT NULL) THEN
  RETURN jsonb_build_object('recorded',false,'code','INVALID_RESULT');
 END IF;
 SELECT * INTO v_attempt FROM henvalt.shopify_pixel_send_attempts_v2
 WHERE id=p_send_attempt_id FOR UPDATE;
 IF NOT FOUND THEN RETURN jsonb_build_object('recorded',false,'code','ATTEMPT_NOT_FOUND'); END IF;
 IF v_attempt.status NOT IN ('AUTHORIZED','AMBIGUOUS')
   OR (v_attempt.status='AMBIGUOUS' AND p_status NOT IN ('SUBMITTED','AMBIGUOUS'))
   OR (v_attempt.status='AMBIGUOUS' AND p_status='AMBIGUOUS'
       AND (v_attempt.provider_message_reference IS NOT NULL OR p_provider_message_reference IS NULL)) THEN
  RETURN jsonb_build_object('recorded',false,'code','ATTEMPT_ALREADY_FINALIZED');
 END IF;
 UPDATE henvalt.shopify_pixel_send_attempts_v2
 SET status=p_status,
     provider_message_reference=CASE WHEN p_status IN ('SUBMITTED','AMBIGUOUS')
       THEN coalesce(v_attempt.provider_message_reference,p_provider_message_reference) ELSE NULL END,
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

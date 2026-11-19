-- HENVALT checkout ambiguous provider outcome reconciliation V2.
-- Retain MailerSend message identity when the HTTP response is ambiguous so a
-- later signed event can settle the exact attempt without blind resubmission.
BEGIN;

CREATE OR REPLACE FUNCTION henvalt.record_shopify_delivery_submission_v2(
  p_send_attempt_id uuid,p_outcome text,p_provider_message_id text DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=''
AS $function$
DECLARE
  v_attempt henvalt.shopify_recovery_send_attempt_v2%ROWTYPE;
  v_next_message_id text;
BEGIN
  IF current_setting('request.jwt.claim.role',true) IS DISTINCT FROM 'service_role' THEN
    RAISE EXCEPTION 'service_role_required' USING ERRCODE='42501';
  END IF;
  IF p_send_attempt_id IS NULL
    OR p_outcome IS NULL
    OR p_outcome NOT IN ('SUBMITTED','FAILED','AMBIGUOUS')
    OR (p_provider_message_id IS NOT NULL
      AND p_provider_message_id !~ '^[A-Za-z0-9_-]{10,100}$')
    OR (p_outcome='SUBMITTED' AND p_provider_message_id IS NULL)
    OR (p_outcome='FAILED' AND p_provider_message_id IS NOT NULL) THEN
    RETURN jsonb_build_object('recorded',false,'code','INVALID_REQUEST');
  END IF;

  SELECT * INTO v_attempt
  FROM henvalt.shopify_recovery_send_attempt_v2
  WHERE id=p_send_attempt_id
  FOR UPDATE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('recorded',false,'code','SEND_ATTEMPT_NOT_FOUND');
  END IF;

  IF v_attempt.status='AMBIGUOUS' THEN
    IF p_outcome NOT IN ('SUBMITTED','AMBIGUOUS')
      OR (v_attempt.provider_message_id IS NOT NULL
        AND p_provider_message_id IS NOT NULL
        AND v_attempt.provider_message_id IS DISTINCT FROM p_provider_message_id) THEN
      RETURN jsonb_build_object('recorded',false,'code','SEND_ATTEMPT_ALREADY_FINALIZED');
    END IF;
    IF p_outcome='AMBIGUOUS'
      AND v_attempt.provider_message_id IS NOT NULL
      AND p_provider_message_id IS NULL THEN
      RETURN jsonb_build_object('recorded',true,'status','AMBIGUOUS',
        'provider_message_id_retained',true,'provider_cost_state','RESERVED');
    END IF;
  ELSIF v_attempt.status<>'AUTHORIZED' THEN
    RETURN jsonb_build_object('recorded',false,'code','SEND_ATTEMPT_ALREADY_FINALIZED');
  END IF;

  v_next_message_id:=CASE
    WHEN p_outcome='SUBMITTED' THEN p_provider_message_id
    WHEN p_outcome='AMBIGUOUS' THEN coalesce(v_attempt.provider_message_id,p_provider_message_id)
    ELSE NULL
  END;

  UPDATE henvalt.shopify_recovery_send_attempt_v2
  SET status=p_outcome,
      provider_message_id=v_next_message_id,
      submitted_at=CASE WHEN p_outcome='SUBMITTED' THEN coalesce(submitted_at,pg_catalog.now()) ELSE submitted_at END,
      updated_at=pg_catalog.now()
  WHERE id=p_send_attempt_id
    AND (status='AUTHORIZED' OR status='AMBIGUOUS');

  UPDATE henvalt.shopify_recovery_intervention_v2
  SET status=p_outcome,updated_at=pg_catalog.now()
  WHERE id=v_attempt.intervention_id
    AND tenant_id=v_attempt.tenant_id
    AND shopify_connection_id=v_attempt.shopify_connection_id
    AND status IN ('AUTHORIZED','AMBIGUOUS');

  RETURN jsonb_build_object(
    'recorded',true,
    'status',p_outcome,
    'provider_message_id_retained',v_next_message_id IS NOT NULL,
    'provider_cost_state',CASE
      WHEN p_outcome='SUBMITTED' THEN 'SETTLED'
      WHEN p_outcome='FAILED' THEN 'RELEASED'
      ELSE 'RESERVED' END
  );
END;
$function$;

CREATE OR REPLACE FUNCTION henvalt.reconcile_shopify_checkout_provider_event_mapping_v2()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path=''
AS $function$
BEGIN
  IF NEW.send_attempt_id IS NOT NULL
    AND NEW.processing_status='PROCESSED'
    AND NEW.event_type='activity.sent' THEN
    UPDATE henvalt.shopify_recovery_send_attempt_v2
    SET status='SUBMITTED',
        submitted_at=coalesce(submitted_at,pg_catalog.now()),
        updated_at=pg_catalog.now()
    WHERE id=NEW.send_attempt_id
      AND provider_account_key=NEW.provider_account_key
      AND provider_message_id=NEW.provider_message_id
      AND status='AMBIGUOUS';

    UPDATE henvalt.shopify_recovery_intervention_v2 i
    SET status='SUBMITTED',updated_at=pg_catalog.now()
    FROM henvalt.shopify_recovery_send_attempt_v2 a
    WHERE a.id=NEW.send_attempt_id
      AND a.intervention_id=i.id
      AND a.tenant_id=i.tenant_id
      AND a.shopify_connection_id=i.shopify_connection_id
      AND a.status='SUBMITTED'
      AND i.status='AMBIGUOUS';
  END IF;
  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS shopify_checkout_provider_event_mapping_v2
  ON henvalt.shopify_mailer_provider_events_v2;
CREATE TRIGGER shopify_checkout_provider_event_mapping_v2
AFTER UPDATE OF send_attempt_id,processing_status
ON henvalt.shopify_mailer_provider_events_v2
FOR EACH ROW
WHEN (NEW.send_attempt_id IS NOT NULL AND NEW.processing_status='PROCESSED')
EXECUTE FUNCTION henvalt.reconcile_shopify_checkout_provider_event_mapping_v2();

CREATE OR REPLACE FUNCTION henvalt.reconcile_unmatched_shopify_checkout_provider_events_v2(
  p_limit integer DEFAULT 100
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=''
AS $function$
DECLARE
  v_event record;
  v_attempt record;
  v_locked_event record;
  v_count integer:=0;
  v_suppression_type text;
BEGIN
  IF current_setting('request.jwt.claim.role',true) IS DISTINCT FROM 'service_role' THEN
    RAISE EXCEPTION 'service_role_required' USING ERRCODE='42501';
  END IF;
  IF p_limit IS NULL OR p_limit<1 OR p_limit>500 THEN
    RETURN jsonb_build_object('accepted',false,'code','INVALID_RECONCILIATION_LIMIT');
  END IF;

  FOR v_event IN
    SELECT e.id,e.provider_event_id,e.provider_account_key,e.provider_message_id,e.event_type
    FROM henvalt.shopify_mailer_provider_events_v2 e
    JOIN henvalt.shopify_recovery_send_attempt_v2 matched_attempt
      ON matched_attempt.provider_account_key=e.provider_account_key
     AND matched_attempt.provider_message_id=e.provider_message_id
    WHERE e.processing_status='UNMATCHED'
      AND e.provider_message_id IS NOT NULL
      AND e.event_type IN (
        'activity.sent','activity.delivered','activity.soft_bounced',
        'activity.hard_bounced','activity.unsubscribed','activity.spam_complaint'
      )
    ORDER BY e.created_at,e.id
    LIMIT p_limit
  LOOP
    SELECT a.id,a.tenant_id,a.shopify_connection_id,a.customer_identity_id,
      a.intervention_id,a.status,a.provider_message_id,a.provider_account_key
    INTO v_attempt
    FROM henvalt.shopify_recovery_send_attempt_v2 a
    WHERE a.provider_account_key=v_event.provider_account_key
      AND a.provider_message_id=v_event.provider_message_id
    FOR UPDATE;
    IF NOT FOUND THEN CONTINUE; END IF;

    -- Match ingest's attempt-first, event-second lock order to avoid deadlocks.
    SELECT e.id INTO v_locked_event
    FROM henvalt.shopify_mailer_provider_events_v2 e
    WHERE e.id=v_event.id AND e.processing_status='UNMATCHED'
    FOR UPDATE;
    IF NOT FOUND THEN CONTINUE; END IF;

    v_suppression_type:=CASE v_event.event_type
      WHEN 'activity.unsubscribed' THEN 'UNSUBSCRIBED'
      WHEN 'activity.spam_complaint' THEN 'SPAM_COMPLAINT'
      WHEN 'activity.hard_bounced' THEN 'HARD_BOUNCE'
      ELSE NULL END;

    IF v_suppression_type IS NOT NULL AND NOT EXISTS (
      SELECT 1 FROM henvalt.shopify_delivery_permits_v2 permit_row
      WHERE permit_row.send_attempt_id=v_attempt.id
        AND permit_row.tenant_id=v_attempt.tenant_id
        AND permit_row.shopify_connection_id=v_attempt.shopify_connection_id
        AND pg_catalog.octet_length(permit_row.recipient_fingerprint)=32
    ) THEN
      -- Do not mark a suppression event processed without the original recipient fingerprint.
      CONTINUE;
    END IF;

    IF v_event.event_type='activity.sent' THEN
      UPDATE henvalt.shopify_recovery_send_attempt_v2
      SET status='SUBMITTED',submitted_at=coalesce(submitted_at,pg_catalog.now()),updated_at=pg_catalog.now()
      WHERE id=v_attempt.id AND status='AMBIGUOUS';
    ELSIF v_event.event_type='activity.delivered' AND v_attempt.status IN ('SUBMITTED','AMBIGUOUS') THEN
      UPDATE henvalt.shopify_recovery_send_attempt_v2
      SET status='DELIVERED',delivered_at=coalesce(delivered_at,pg_catalog.now()),updated_at=pg_catalog.now()
      WHERE id=v_attempt.id AND status IN ('SUBMITTED','AMBIGUOUS');
      UPDATE henvalt.shopify_recovery_intervention_v2
      SET status='DELIVERED',updated_at=pg_catalog.now()
      WHERE id=v_attempt.intervention_id
        AND tenant_id=v_attempt.tenant_id
        AND shopify_connection_id=v_attempt.shopify_connection_id
        AND status IN ('SUBMITTED','AMBIGUOUS');
    ELSIF v_event.event_type='activity.soft_bounced' AND v_attempt.status IN ('SUBMITTED','AMBIGUOUS') THEN
      UPDATE henvalt.shopify_recovery_send_attempt_v2
      SET status='SOFT_BOUNCED',updated_at=pg_catalog.now()
      WHERE id=v_attempt.id AND status IN ('SUBMITTED','AMBIGUOUS');
    ELSIF v_event.event_type='activity.hard_bounced' THEN
      UPDATE henvalt.shopify_recovery_send_attempt_v2
      SET status='HARD_BOUNCED',updated_at=pg_catalog.now()
      WHERE id=v_attempt.id AND status IN ('SUBMITTED','AMBIGUOUS','DELIVERED','SOFT_BOUNCED');
    ELSIF v_event.event_type='activity.unsubscribed' THEN
      UPDATE henvalt.shopify_recovery_send_attempt_v2
      SET status='UNSUBSCRIBED',updated_at=pg_catalog.now()
      WHERE id=v_attempt.id AND status IN ('SUBMITTED','AMBIGUOUS','DELIVERED','SOFT_BOUNCED');
    ELSIF v_event.event_type='activity.spam_complaint' THEN
      UPDATE henvalt.shopify_recovery_send_attempt_v2
      SET status='COMPLAINED',updated_at=pg_catalog.now()
      WHERE id=v_attempt.id AND status IN ('SUBMITTED','AMBIGUOUS','DELIVERED','SOFT_BOUNCED');
    END IF;

    IF v_event.event_type='activity.sent' THEN
      UPDATE henvalt.shopify_recovery_intervention_v2 i
      SET status='SUBMITTED',updated_at=pg_catalog.now()
      FROM henvalt.shopify_recovery_send_attempt_v2 a
      WHERE a.id=v_attempt.id AND a.status='SUBMITTED'
        AND a.intervention_id=i.id AND a.tenant_id=i.tenant_id
        AND a.shopify_connection_id=i.shopify_connection_id
        AND i.status='AMBIGUOUS';
    ELSIF v_event.event_type='activity.delivered' THEN
      UPDATE henvalt.shopify_recovery_intervention_v2 i
      SET status='DELIVERED',updated_at=pg_catalog.now()
      FROM henvalt.shopify_recovery_send_attempt_v2 a
      WHERE a.id=v_attempt.id AND a.status='DELIVERED'
        AND a.intervention_id=i.id AND a.tenant_id=i.tenant_id
        AND a.shopify_connection_id=i.shopify_connection_id
        AND i.status IN ('SUBMITTED','AMBIGUOUS');
    END IF;

    IF v_suppression_type IS NOT NULL THEN
      INSERT INTO henvalt.shopify_delivery_suppressions_v2(
        tenant_id,shopify_connection_id,customer_identity_id,recipient_fingerprint,
        suppression_type,source_send_attempt_id,source_provider_event_id
      )
      SELECT v_attempt.tenant_id,v_attempt.shopify_connection_id,v_attempt.customer_identity_id,
        permit_row.recipient_fingerprint,v_suppression_type,v_attempt.id,v_event.id
      FROM henvalt.shopify_delivery_permits_v2 permit_row
      WHERE permit_row.send_attempt_id=v_attempt.id
        AND permit_row.tenant_id=v_attempt.tenant_id
        AND permit_row.shopify_connection_id=v_attempt.shopify_connection_id
      ON CONFLICT(shopify_connection_id,customer_identity_id,suppression_type,source_provider_event_id)
      DO NOTHING;
    END IF;

    UPDATE henvalt.shopify_mailer_provider_events_v2
    SET tenant_id=v_attempt.tenant_id,
        shopify_connection_id=v_attempt.shopify_connection_id,
        send_attempt_id=v_attempt.id,
        processing_status='PROCESSED'
    WHERE id=v_event.id AND processing_status='UNMATCHED';

    v_count:=v_count+1;
  END LOOP;

  RETURN jsonb_build_object('accepted',true,'reconciled',v_count,
    'automatic_resend_performed',false,'ambiguous_cost_reservation_released',false);
END;
$function$;

CREATE OR REPLACE FUNCTION henvalt.mark_stale_shopify_checkout_send_attempts_ambiguous_v2(
  p_before timestamptz DEFAULT (pg_catalog.now()-interval '2 minutes'),
  p_limit integer DEFAULT 100
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=''
AS $function$
DECLARE
  v_count integer:=0;
BEGIN
  IF current_setting('request.jwt.claim.role',true) IS DISTINCT FROM 'service_role' THEN
    RAISE EXCEPTION 'service_role_required' USING ERRCODE='42501';
  END IF;
  IF p_before IS NULL OR p_before>pg_catalog.now()-interval '2 minutes'
    OR p_before<pg_catalog.now()-interval '24 hours'
    OR p_limit IS NULL OR p_limit<1 OR p_limit>500 THEN
    RETURN jsonb_build_object('accepted',false,'code','INVALID_RECONCILIATION_WINDOW');
  END IF;

  WITH stale AS (
    SELECT a.id,a.tenant_id,a.shopify_connection_id,a.intervention_id
    FROM henvalt.shopify_recovery_send_attempt_v2 a
    WHERE a.status='AUTHORIZED' AND a.created_at<=p_before
    ORDER BY a.created_at,a.id
    LIMIT p_limit
    FOR UPDATE SKIP LOCKED
  ), changed AS (
    UPDATE henvalt.shopify_recovery_send_attempt_v2 a
    SET status='AMBIGUOUS',updated_at=pg_catalog.now()
    FROM stale
    WHERE a.id=stale.id AND a.status='AUTHORIZED'
    RETURNING a.id,a.tenant_id,a.shopify_connection_id,a.intervention_id
  ), interventions AS (
    UPDATE henvalt.shopify_recovery_intervention_v2 i
    SET status='AMBIGUOUS',updated_at=pg_catalog.now()
    FROM changed
    WHERE i.id=changed.intervention_id
      AND i.tenant_id=changed.tenant_id
      AND i.shopify_connection_id=changed.shopify_connection_id
      AND i.status='AUTHORIZED'
    RETURNING i.id
  )
  SELECT count(*)::integer INTO v_count FROM changed;

  RETURN jsonb_build_object('accepted',true,'marked_ambiguous',v_count,
    'provider_cost_reservation_released',false,'automatic_retry_performed',false);
END;
$function$;

REVOKE ALL ON FUNCTION henvalt.record_shopify_delivery_submission_v2(uuid,text,text)
  FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION henvalt.record_shopify_delivery_submission_v2(uuid,text,text)
  TO service_role;
REVOKE ALL ON FUNCTION henvalt.reconcile_shopify_checkout_provider_event_mapping_v2()
  FROM PUBLIC,anon,authenticated,service_role;
REVOKE ALL ON FUNCTION henvalt.reconcile_unmatched_shopify_checkout_provider_events_v2(integer)
  FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION henvalt.reconcile_unmatched_shopify_checkout_provider_events_v2(integer)
  TO service_role;
REVOKE ALL ON FUNCTION henvalt.mark_stale_shopify_checkout_send_attempts_ambiguous_v2(timestamptz,integer)
  FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION henvalt.mark_stale_shopify_checkout_send_attempts_ambiguous_v2(timestamptz,integer)
  TO service_role;

COMMIT;

-- HENVALT bounded pixel provider-event reconciliation sweep V2.
-- Reuses the verified per-event reconciler; never sends, retries, or releases reservations.
BEGIN;

CREATE OR REPLACE FUNCTION henvalt.reconcile_unmatched_shopify_pixel_provider_events_v2(
  p_limit integer DEFAULT 100
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=''
AS $function$
DECLARE
  v_event record;
  v_result jsonb;
  v_reconciled integer:=0;
  v_deferred integer:=0;
BEGIN
  IF current_setting('request.jwt.claim.role',true) IS DISTINCT FROM 'service_role' THEN
    RAISE EXCEPTION 'service_role_required' USING ERRCODE='42501';
  END IF;
  IF p_limit IS NULL OR p_limit<1 OR p_limit>500 THEN
    RETURN jsonb_build_object('accepted',false,'code','INVALID_RECONCILIATION_LIMIT');
  END IF;

  -- Only select events whose exact provider account + message reference now
  -- exists on a pixel attempt. The per-event RPC owns row locking, lineage
  -- validation, suppression, and idempotency.
  FOR v_event IN
    SELECT e.provider_account_key,e.provider_event_id
    FROM henvalt.shopify_mailer_provider_events_v2 e
    JOIN henvalt.shopify_pixel_send_attempts_v2 a
      ON a.provider_account_key=e.provider_account_key
     AND a.provider_message_reference=e.provider_message_id
    WHERE e.processing_status='UNMATCHED'
      AND e.pixel_send_attempt_id IS NULL
      AND e.provider_message_id IS NOT NULL
      AND e.event_type IN (
        'activity.sent','activity.delivered','activity.soft_bounced',
        'activity.hard_bounced','activity.unsubscribed','activity.spam_complaint',
        'activity.opened','activity.clicked'
      )
    ORDER BY e.created_at,e.id
    LIMIT p_limit
  LOOP
    v_result:=henvalt.reconcile_mailersend_pixel_provider_event_v2(
      v_event.provider_account_key,v_event.provider_event_id
    );
    IF coalesce((v_result->>'accepted')::boolean,false) IS NOT TRUE THEN
      RETURN jsonb_build_object('accepted',false,'code','PIXEL_EVENT_RECONCILIATION_UNCONFIRMED',
        'reconciled',v_reconciled,'deferred',v_deferred);
    END IF;
    IF v_result->>'status' IN ('PROCESSED','DUPLICATE') THEN
      v_reconciled:=v_reconciled+1;
    ELSE
      v_deferred:=v_deferred+1;
    END IF;
  END LOOP;

  RETURN jsonb_build_object(
    'accepted',true,
    'reconciled',v_reconciled,
    'deferred',v_deferred,
    'automatic_resend_performed',false,
    'ambiguous_cost_reservation_released',false,
    'provider_called',false,
    'recipient_pii_returned',false
  );
END;
$function$;

REVOKE ALL ON FUNCTION henvalt.reconcile_unmatched_shopify_pixel_provider_events_v2(integer)
  FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION henvalt.reconcile_unmatched_shopify_pixel_provider_events_v2(integer)
  TO service_role;

COMMIT;

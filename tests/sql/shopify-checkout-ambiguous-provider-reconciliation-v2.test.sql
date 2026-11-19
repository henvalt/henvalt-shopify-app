-- Structural and privilege contract for checkout provider ambiguity reconciliation.
DO $test$
DECLARE
  v_record text;
  v_reconcile text;
  v_trigger text;
  v_stale text;
BEGIN
  SELECT pg_catalog.pg_get_functiondef(
    'henvalt.record_shopify_delivery_submission_v2(uuid,text,text)'::regprocedure
  ) INTO v_record;
  SELECT pg_catalog.pg_get_functiondef(
    'henvalt.reconcile_unmatched_shopify_checkout_provider_events_v2(integer)'::regprocedure
  ) INTO v_reconcile;
  SELECT pg_catalog.pg_get_functiondef(
    'henvalt.reconcile_shopify_checkout_provider_event_mapping_v2()'::regprocedure
  ) INTO v_trigger;
  SELECT pg_catalog.pg_get_functiondef(
    'henvalt.mark_stale_shopify_checkout_send_attempts_ambiguous_v2(timestamptz,integer)'::regprocedure
  ) INTO v_stale;

  IF position('WHEN p_outcome=''AMBIGUOUS'' THEN coalesce(v_attempt.provider_message_id,p_provider_message_id)' in v_record)=0
    OR position('p_outcome NOT IN (''SUBMITTED'',''AMBIGUOUS'')' in v_record)=0
    OR position('NEW.event_type=''activity.sent''' in v_trigger)=0
    OR position('matched_attempt.provider_message_id=e.provider_message_id' in v_reconcile)=0
    OR position('LIMIT p_limit' in v_reconcile)=0
    OR position('attempt-first, event-second lock order' in v_reconcile)=0
    OR position('permit_row.recipient_fingerprint' in v_reconcile)=0
    OR position('activity.spam_complaint' in v_reconcile)=0
    OR position('FOR UPDATE SKIP LOCKED' in v_stale)=0
    OR position('provider_cost_reservation_released' in v_stale)=0
    OR position('automatic_retry_performed' in v_stale)=0 THEN
    RAISE EXCEPTION 'Checkout provider ambiguity reconciliation contract is incomplete';
  END IF;

  IF has_function_privilege('anon','henvalt.mark_stale_shopify_checkout_send_attempts_ambiguous_v2(timestamptz,integer)','EXECUTE')
    OR has_function_privilege('authenticated','henvalt.mark_stale_shopify_checkout_send_attempts_ambiguous_v2(timestamptz,integer)','EXECUTE')
    OR NOT has_function_privilege('service_role','henvalt.mark_stale_shopify_checkout_send_attempts_ambiguous_v2(timestamptz,integer)','EXECUTE') THEN
    RAISE EXCEPTION 'Stale checkout reconciler privilege boundary is invalid';
  END IF;

  IF has_function_privilege('anon','henvalt.reconcile_unmatched_shopify_checkout_provider_events_v2(integer)','EXECUTE')
    OR has_function_privilege('authenticated','henvalt.reconcile_unmatched_shopify_checkout_provider_events_v2(integer)','EXECUTE')
    OR NOT has_function_privilege('service_role','henvalt.reconcile_unmatched_shopify_checkout_provider_events_v2(integer)','EXECUTE') THEN
    RAISE EXCEPTION 'Checkout provider reconciler privilege boundary is invalid';
  END IF;
END;
$test$;
SELECT 'shopify_checkout_ambiguous_provider_reconciliation_passed' AS result;

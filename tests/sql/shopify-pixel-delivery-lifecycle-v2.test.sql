-- Integration checks for independent pixel delivery lifecycle (migrations 034-038).
-- This test creates no customer, permit, attempt, reservation, or provider request.
DO $test$
DECLARE v_result jsonb; v_table text; v_function text;
BEGIN
  FOREACH v_table IN ARRAY ARRAY[
    'shopify_pixel_delivery_permits_v2',
    'shopify_pixel_send_attempts_v2',
    'shopify_pixel_delivery_cost_reservations_v2'
  ] LOOP
    IF NOT EXISTS (
      SELECT 1 FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
      WHERE n.nspname='henvalt' AND c.relname=v_table AND c.relrowsecurity
    ) THEN RAISE EXCEPTION 'RLS is not enabled on %',v_table; END IF;
    IF has_table_privilege('anon','henvalt.'||v_table,'SELECT')
      OR has_table_privilege('authenticated','henvalt.'||v_table,'SELECT')
      OR has_table_privilege('service_role','henvalt.'||v_table,'SELECT') THEN
      RAISE EXCEPTION 'Direct table SELECT unexpectedly granted on %',v_table;
    END IF;
  END LOOP;

  FOREACH v_function IN ARRAY ARRAY[
    'henvalt.issue_shopify_pixel_delivery_permit_v2(uuid,text,uuid,text)',
    'henvalt.consume_shopify_pixel_delivery_permit_v2(text)',
    'henvalt.resolve_shopify_pixel_delivery_context_v2(uuid)',
    'henvalt.authorize_shopify_pixel_provider_submission_v2(uuid,text)',
    'henvalt.record_shopify_pixel_send_attempt_result_v2(uuid,text,text)',
    'henvalt.mark_stale_shopify_pixel_send_attempts_ambiguous_v2(timestamp with time zone,integer)'
  ] LOOP
    IF has_function_privilege('anon',v_function,'EXECUTE')
      OR has_function_privilege('authenticated',v_function,'EXECUTE')
      OR NOT has_function_privilege('service_role',v_function,'EXECUTE') THEN
      RAISE EXCEPTION 'Function privilege boundary invalid for %',v_function;
    END IF;
  END LOOP;

  IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname='shopify_pixel_delivery_cost_reserve_v2' AND NOT tgisinternal)
    OR NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname='shopify_pixel_delivery_cost_sync_v2' AND NOT tgisinternal)
    OR NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname='shopify_delivery_cost_reserve_after_attempt_v2' AND NOT tgisinternal) THEN
    RAISE EXCEPTION 'Pixel and checkout reservation lifecycle triggers are incomplete';
  END IF;

  IF EXISTS (SELECT 1 FROM henvalt.shopify_pixel_send_attempts_v2) THEN
    RAISE EXCEPTION 'Lifecycle smoke test expects no pixel attempts before no-op reconciler check';
  END IF;

  PERFORM pg_catalog.set_config('request.jwt.claim.role','service_role',true);
  v_result:=henvalt.mark_stale_shopify_pixel_send_attempts_ambiguous_v2(
    pg_catalog.now()-interval '3 minutes',10
  );
  IF v_result->>'accepted'<>'true'
    OR (v_result->>'marked_ambiguous')::integer<>0
    OR v_result->>'provider_cost_reservation_released'<>'false'
    OR v_result->>'automatic_retry_performed'<>'false' THEN
    RAISE EXCEPTION 'Empty stale-attempt reconciliation was not a safe no-op: %',v_result;
  END IF;

  v_result:=henvalt.mark_stale_shopify_pixel_send_attempts_ambiguous_v2(
    pg_catalog.now()-interval '1 minute',10
  );
  IF v_result->>'accepted'<>'false' THEN
    RAISE EXCEPTION 'Reconciler accepted a window that was too recent: %',v_result;
  END IF;
END;
$test$;
SELECT 'shopify_pixel_delivery_lifecycle_passed' AS result;

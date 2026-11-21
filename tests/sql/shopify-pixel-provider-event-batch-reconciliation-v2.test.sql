-- Structural and privilege contract for bounded pixel provider-event reconciliation.
DO $test$
DECLARE
  v_def text;
  v_acl text[];
BEGIN
  SELECT pg_catalog.pg_get_functiondef(
    'henvalt.reconcile_unmatched_shopify_pixel_provider_events_v2(integer)'::regprocedure
  ) INTO v_def;
  IF v_def NOT LIKE '%request.jwt.claim.role%' OR v_def NOT LIKE '%service_role%'
    OR v_def NOT LIKE '%p_limit<1 OR p_limit>500%'
    OR v_def NOT LIKE '%reconcile_mailersend_pixel_provider_event_v2%'
    OR v_def NOT LIKE '%automatic_resend_performed%'
    OR v_def NOT LIKE '%ambiguous_cost_reservation_released%'
    OR v_def NOT LIKE '%provider_called%'
    OR v_def NOT LIKE '%recipient_pii_returned%' THEN
    RAISE EXCEPTION 'Pixel batch reconciler is missing a required safety contract';
  END IF;
  IF v_def LIKE '%henvalt.shopify_pixel_delivery_permits_v2%' THEN
    RAISE EXCEPTION 'Pixel batch reconciler must delegate suppression/permit handling to the per-event reconciler';
  END IF;
  SELECT coalesce(array_agg(grantee::text),ARRAY[]::text[]) INTO v_acl
  FROM information_schema.routine_privileges
  WHERE specific_schema='henvalt'
    AND routine_name='reconcile_unmatched_shopify_pixel_provider_events_v2';
  IF NOT ('service_role'=ANY(v_acl)) OR 'anon'=ANY(v_acl) OR 'authenticated'=ANY(v_acl) THEN
    RAISE EXCEPTION 'Pixel batch reconciler privileges are not service-role-only: %',v_acl;
  END IF;
END;
$test$;

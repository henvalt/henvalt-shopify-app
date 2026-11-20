-- Structural PostgreSQL checks for the final pixel provider-submission gate.
-- No fixture, permit, attempt, provider call or customer data is created.
DO $test$
DECLARE
  v_definition text;
  v_result jsonb;
BEGIN
  SELECT pg_catalog.pg_get_functiondef(
    'henvalt.authorize_shopify_pixel_provider_submission_v2(uuid,text)'::regprocedure
  ) INTO v_definition;

  IF v_definition IS NULL
    OR position('permit_row.tenant_id=attempt_row.tenant_id' in v_definition)=0
    OR position('permit_row.shopify_connection_id=attempt_row.shopify_connection_id' in v_definition)=0
    OR position('reservation_row.tenant_id=attempt_row.tenant_id' in v_definition)=0
    OR position('reservation_row.shopify_connection_id=attempt_row.shopify_connection_id' in v_definition)=0
    OR position('recipient_fingerprint' in v_definition)=0
    OR position('shopify_delivery_suppressions_v2' in v_definition)=0
    OR position('assess_shopify_pixel_delivery_eligibility_v2' in v_definition)=0
    OR position('FOR UPDATE' in v_definition)=0 THEN
    RAISE EXCEPTION 'Final pixel gate is missing a required exact-store delivery boundary';
  END IF;

  IF has_function_privilege('anon','henvalt.authorize_shopify_pixel_provider_submission_v2(uuid,text)','EXECUTE')
    OR has_function_privilege('authenticated','henvalt.authorize_shopify_pixel_provider_submission_v2(uuid,text)','EXECUTE')
    OR NOT has_function_privilege('service_role','henvalt.authorize_shopify_pixel_provider_submission_v2(uuid,text)','EXECUTE') THEN
    RAISE EXCEPTION 'Final pixel gate privilege boundary is invalid';
  END IF;

  PERFORM pg_catalog.set_config('request.jwt.claim.role','service_role',true);
  v_result:=henvalt.authorize_shopify_pixel_provider_submission_v2(NULL,NULL);
  IF v_result->>'authorized'<>'false' OR v_result->>'code'<>'INVALID_REQUEST' THEN
    RAISE EXCEPTION 'Final pixel gate did not fail closed on invalid input: %',v_result;
  END IF;
END;
$test$;
SELECT 'shopify_pixel_provider_submission_gate_passed' AS result;

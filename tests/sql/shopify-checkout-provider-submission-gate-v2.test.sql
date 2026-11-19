-- Structural PostgreSQL checks for the final checkout provider-submission gate.
-- No fixture, permit, attempt, provider call or customer data is created.
DO $test$
DECLARE
  v_definition text;
  v_result jsonb;
BEGIN
  SELECT pg_catalog.pg_get_functiondef(
    'henvalt.authorize_shopify_delivery_provider_submission_v2(uuid,text)'::regprocedure
  ) INTO v_definition;

  IF v_definition IS NULL
    OR position('sc.active IS DISTINCT FROM true' in v_definition)=0
    OR position('sc.app_key IS DISTINCT FROM v_attempt.app_key' in v_definition)=0
    OR position('v_attempt.checkout_status IS DISTINCT FROM' in v_definition)=0
    OR position('v_attempt.marketing_state IS DISTINCT FROM' in v_definition)=0
    OR position('shopify_order_identity_v2' in v_definition)=0
    OR position('shopify_delivery_suppressions_v2' in v_definition)=0
    OR position('shopify_customer_redaction_guards_v2' in v_definition)=0
    OR position('reservation_row.status' in v_definition)=0
    OR position('jurisdiction_country_code IS NULL' in v_definition)=0
    OR position('FOR UPDATE' in v_definition)=0 THEN
    RAISE EXCEPTION 'Final checkout gate is missing a required delivery boundary';
  END IF;

  IF has_function_privilege('anon','henvalt.authorize_shopify_delivery_provider_submission_v2(uuid,text)','EXECUTE')
    OR has_function_privilege('authenticated','henvalt.authorize_shopify_delivery_provider_submission_v2(uuid,text)','EXECUTE')
    OR NOT has_function_privilege('service_role','henvalt.authorize_shopify_delivery_provider_submission_v2(uuid,text)','EXECUTE') THEN
    RAISE EXCEPTION 'Final checkout gate privilege boundary is invalid';
  END IF;

  PERFORM pg_catalog.set_config('request.jwt.claim.role','service_role',true);
  v_result:=henvalt.authorize_shopify_delivery_provider_submission_v2(NULL,NULL);
  IF v_result->>'authorized'<>'false' OR v_result->>'code'<>'INVALID_REQUEST' THEN
    RAISE EXCEPTION 'Final checkout gate did not fail closed on invalid input: %',v_result;
  END IF;
END;
$test$;
SELECT 'shopify_checkout_provider_submission_gate_passed' AS result;

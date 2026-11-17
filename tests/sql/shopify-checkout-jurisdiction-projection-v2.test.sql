-- Verified checkout jurisdiction projection integration tests.
\set ON_ERROR_STOP on

DO $jurisdiction_v2$
DECLARE
  v_token text:=repeat('b',64);
  v_secret text:='synthetic-test-secret-never-used-in-production';
  v_body text:='{"token":"jurisdiction-checkout-001","id":null,"currency":"GBP","total_price":"40.00","shipping_address":{"country_code":"GB","address1":"must-not-be-stored","zip":"must-not-be-stored"}}';
  v_unknown_body text:='{"token":"jurisdiction-checkout-unknown","id":null,"currency":"USD","total_price":"20.00"}';
  v_hmac text;
  v_result record;
  v_projected jsonb;
  v_jurisdiction jsonb;
  v_store uuid;
  v_tenant uuid;
BEGIN
  SELECT id,tenant_id INTO v_store,v_tenant FROM henvalt.shopify_connections
  WHERE shop_domain='store-a.myshopify.com';
  IF v_store IS NULL THEN RAISE EXCEPTION 'Store A missing'; END IF;

  v_hmac:=encode(extensions.hmac(convert_to(v_body,'UTF8'),convert_to(v_secret,'UTF8'),'sha256'),'base64');
  SELECT * INTO v_result FROM henvalt.accept_shopify_webhook_v2(
    v_token,v_hmac,encode(convert_to(v_body,'UTF8'),'base64'),
    'store-a.myshopify.com','checkouts/update','jurisdiction-delivery-001','jurisdiction-event-001'
  );
  IF v_result.accepted IS DISTINCT FROM true THEN RAISE EXCEPTION 'Checkout receipt rejected: %',row_to_json(v_result); END IF;

  v_projected:=henvalt.project_verified_shopify_checkout_v2(
    v_token,'jurisdiction-delivery-001',encode(convert_to(v_body,'UTF8'),'base64')
  );
  IF v_projected->>'accepted'<>'true' THEN RAISE EXCEPTION 'Checkout identity projection failed: %',v_projected; END IF;

  v_jurisdiction:=henvalt.project_verified_shopify_checkout_jurisdiction_v2(
    v_token,'jurisdiction-delivery-001',encode(convert_to(v_body,'UTF8'),'base64')
  );
  IF v_jurisdiction->>'accepted'<>'true' OR v_jurisdiction->>'jurisdiction_country_code'<>'GB' THEN
    RAISE EXCEPTION 'GB checkout country not projected: %',v_jurisdiction;
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM henvalt.shopify_checkout_identity_v2
    WHERE tenant_id=v_tenant AND shopify_connection_id=v_store
      AND shopify_checkout_token='jurisdiction-checkout-001'
      AND jurisdiction_country_code='GB'
  ) THEN RAISE EXCEPTION 'Exact-store country code missing'; END IF;

  v_hmac:=encode(extensions.hmac(convert_to(v_unknown_body,'UTF8'),convert_to(v_secret,'UTF8'),'sha256'),'base64');
  SELECT * INTO v_result FROM henvalt.accept_shopify_webhook_v2(
    v_token,v_hmac,encode(convert_to(v_unknown_body,'UTF8'),'base64'),
    'store-a.myshopify.com','checkouts/update','jurisdiction-delivery-002','jurisdiction-event-002'
  );
  IF v_result.accepted IS DISTINCT FROM true THEN RAISE EXCEPTION 'Unknown-country checkout receipt rejected'; END IF;
  v_projected:=henvalt.project_verified_shopify_checkout_v2(
    v_token,'jurisdiction-delivery-002',encode(convert_to(v_unknown_body,'UTF8'),'base64')
  );
  IF v_projected->>'accepted'<>'true' THEN RAISE EXCEPTION 'Unknown-country checkout identity projection failed'; END IF;
  v_jurisdiction:=henvalt.project_verified_shopify_checkout_jurisdiction_v2(
    v_token,'jurisdiction-delivery-002',encode(convert_to(v_unknown_body,'UTF8'),'base64')
  );
  IF v_jurisdiction->>'accepted'<>'true' OR v_jurisdiction->>'jurisdiction_known'<>'false' THEN
    RAISE EXCEPTION 'Unknown country did not remain unknown: %',v_jurisdiction;
  END IF;
  IF EXISTS (
    SELECT 1 FROM henvalt.shopify_checkout_identity_v2
    WHERE tenant_id=v_tenant AND shopify_connection_id=v_store
      AND shopify_checkout_token='jurisdiction-checkout-unknown'
      AND jurisdiction_country_code IS NOT NULL
  ) THEN RAISE EXCEPTION 'Jurisdiction was inferred without checkout country evidence'; END IF;

  IF has_function_privilege('anon','henvalt.project_verified_shopify_checkout_jurisdiction_v2(text,text,text)','EXECUTE')
     OR has_function_privilege('authenticated','henvalt.project_verified_shopify_checkout_jurisdiction_v2(text,text,text)','EXECUTE')
     OR NOT has_function_privilege('service_role','henvalt.project_verified_shopify_checkout_jurisdiction_v2(text,text,text)','EXECUTE') THEN
    RAISE EXCEPTION 'Jurisdiction projector privileges are not service-role-only';
  END IF;
END;
$jurisdiction_v2$;

SELECT 'shopify_checkout_jurisdiction_projection_v2_passed' AS result;

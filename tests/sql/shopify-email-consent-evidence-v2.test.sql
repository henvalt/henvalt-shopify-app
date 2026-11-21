-- Exact-store Shopify email consent evidence integration tests.
\set ON_ERROR_STOP on

DO $consent_v2$
DECLARE
  v_token text := repeat('b',64);
  v_secret text := 'synthetic-test-secret-never-used-in-production';
  v_body text := '{"customer_id":12345,"email_address":"must-not-be-stored@example.invalid","email_marketing_consent":{"state":"subscribed","opt_in_level":"single_opt_in","consent_updated_at":"2026-11-17T04:00:00Z"}}';
  v_older_body text := '{"customer_id":12345,"email_address":"must-not-be-stored@example.invalid","email_marketing_consent":{"state":"unsubscribed","opt_in_level":"single_opt_in","consent_updated_at":"2026-11-17T03:00:00Z"}}';
  v_conflict_body text := '{"customer_id":12345,"email_address":"must-not-be-stored@example.invalid","email_marketing_consent":{"state":"unsubscribed","opt_in_level":"single_opt_in","consent_updated_at":"2026-11-17T04:00:00Z"}}';
  v_hmac text;
  v_result record;
  v_projected jsonb;
  v_store_a uuid;
  v_tenant uuid;
  v_customer uuid;
BEGIN
  SELECT id,tenant_id INTO v_store_a,v_tenant
  FROM henvalt.shopify_connections WHERE shop_domain='store-a.myshopify.com';
  IF v_store_a IS NULL THEN RAISE EXCEPTION 'Store A missing for consent integration'; END IF;

  v_hmac:=encode(extensions.hmac(convert_to(v_body,'UTF8'),convert_to(v_secret,'UTF8'),'sha256'),'base64');
  SELECT * INTO v_result FROM henvalt.accept_shopify_webhook_v2(
    v_token,v_hmac,encode(convert_to(v_body,'UTF8'),'base64'),
    'store-a.myshopify.com','customers_email_marketing_consent/update',
    'consent-delivery-001','consent-event-001'
  );
  IF v_result.accepted IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'Signed consent webhook not accepted: %',row_to_json(v_result);
  END IF;

  v_projected:=henvalt.project_verified_shopify_email_consent_v2(
    v_token,'consent-delivery-001',encode(convert_to(v_body,'UTF8'),'base64')
  );
  IF v_projected->>'accepted'<>'true' OR v_projected->>'consent_state'<>'SUBSCRIBED' THEN
    RAISE EXCEPTION 'Subscribed consent did not project: %',v_projected;
  END IF;

  SELECT id INTO v_customer FROM henvalt.shopify_customer_identity_v2
  WHERE tenant_id=v_tenant AND shopify_connection_id=v_store_a
    AND external_customer_reference='12345';
  IF v_customer IS NULL OR NOT EXISTS (
    SELECT 1 FROM henvalt.shopify_customer_email_consent_v2
    WHERE shopify_connection_id=v_store_a AND customer_identity_id=v_customer
      AND marketing_state='SUBSCRIBED'
  ) THEN RAISE EXCEPTION 'Current exact-store consent row missing'; END IF;

  -- Exact receipt replay must not downgrade or otherwise re-apply evidence.
  v_projected:=henvalt.project_verified_shopify_email_consent_v2(
    v_token,'consent-delivery-001',encode(convert_to(v_body,'UTF8'),'base64')
  );
  IF v_projected->>'status'<>'DUPLICATE' OR NOT EXISTS (
    SELECT 1 FROM henvalt.shopify_customer_email_consent_v2
    WHERE shopify_connection_id=v_store_a AND customer_identity_id=v_customer
      AND marketing_state='SUBSCRIBED'
  ) THEN RAISE EXCEPTION 'Consent receipt replay changed current state: %',v_projected; END IF;

  -- A late-arriving older unsubscribe cannot overwrite newer subscription.
  v_hmac:=encode(extensions.hmac(convert_to(v_older_body,'UTF8'),convert_to(v_secret,'UTF8'),'sha256'),'base64');
  SELECT * INTO v_result FROM henvalt.accept_shopify_webhook_v2(
    v_token,v_hmac,encode(convert_to(v_older_body,'UTF8'),'base64'),
    'store-a.myshopify.com','customers_email_marketing_consent/update',
    'consent-delivery-002','consent-event-002'
  );
  IF v_result.accepted IS DISTINCT FROM true THEN RAISE EXCEPTION 'Older consent event not accepted'; END IF;
  v_projected:=henvalt.project_verified_shopify_email_consent_v2(
    v_token,'consent-delivery-002',encode(convert_to(v_older_body,'UTF8'),'base64')
  );
  IF NOT EXISTS (
    SELECT 1 FROM henvalt.shopify_customer_email_consent_v2
    WHERE shopify_connection_id=v_store_a AND customer_identity_id=v_customer
      AND marketing_state='SUBSCRIBED'
  ) THEN RAISE EXCEPTION 'Out-of-order older event overwrote current consent'; END IF;

  -- Conflicting states at the exact same source timestamp become UNKNOWN.
  v_hmac:=encode(extensions.hmac(convert_to(v_conflict_body,'UTF8'),convert_to(v_secret,'UTF8'),'sha256'),'base64');
  SELECT * INTO v_result FROM henvalt.accept_shopify_webhook_v2(
    v_token,v_hmac,encode(convert_to(v_conflict_body,'UTF8'),'base64'),
    'store-a.myshopify.com','customers_email_marketing_consent/update',
    'consent-delivery-003','consent-event-003'
  );
  IF v_result.accepted IS DISTINCT FROM true THEN RAISE EXCEPTION 'Conflicting consent event not accepted'; END IF;
  v_projected:=henvalt.project_verified_shopify_email_consent_v2(
    v_token,'consent-delivery-003',encode(convert_to(v_conflict_body,'UTF8'),'base64')
  );
  IF NOT EXISTS (
    SELECT 1 FROM henvalt.shopify_customer_email_consent_v2
    WHERE shopify_connection_id=v_store_a AND customer_identity_id=v_customer
      AND marketing_state='UNKNOWN'
  ) THEN RAISE EXCEPTION 'Conflicting same-timestamp consent did not fail closed'; END IF;

  IF EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema='henvalt'
      AND table_name IN ('shopify_customer_email_consent_v2','shopify_customer_email_consent_events_v2')
      AND column_name ILIKE '%email%'
  ) THEN RAISE EXCEPTION 'Consent evidence schema unexpectedly stores email fields'; END IF;

  IF has_function_privilege('anon','henvalt.project_verified_shopify_email_consent_v2(text,text,text)','EXECUTE')
     OR has_function_privilege('authenticated','henvalt.project_verified_shopify_email_consent_v2(text,text,text)','EXECUTE')
     OR NOT has_function_privilege('service_role','henvalt.project_verified_shopify_email_consent_v2(text,text,text)','EXECUTE') THEN
    RAISE EXCEPTION 'Consent projector privileges are not service-role-only';
  END IF;
END;
$consent_v2$;

SELECT 'shopify_email_consent_evidence_v2_passed' AS result;

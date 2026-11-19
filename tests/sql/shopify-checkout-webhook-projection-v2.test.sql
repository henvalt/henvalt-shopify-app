-- Two-store verified checkout webhook projection regression.
-- Runs after the existing Shopify V2 integration test on disposable PostgreSQL.
\set ON_ERROR_STOP on
DO $checkout_v2$
DECLARE
  v_tenant uuid := '00000000-0000-4000-8000-000000000001';
  v_store_a uuid;
  v_store_b uuid;
  v_token_a text := repeat('b',64);
  v_token_b text := repeat('c',64);
  v_body_a text := '{"shop_id":"1001","token":"shared-checkout-token","customer":{"id":12345},"total_price":"125.50","currency":"USD","completed_at":null}';
  v_body_b text := '{"shop_id":"2002","token":"shared-checkout-token","customer":{"id":12345},"total_price":"75.00","currency":"GBP","completed_at":null}';
  v_hmac text;
  v_result record;
  v_projection jsonb;
  v_a_count integer;
  v_b_count integer;
BEGIN
  SELECT id INTO v_store_a FROM henvalt.shopify_connections WHERE shop_domain='store-a.myshopify.com';
  SELECT id INTO v_store_b FROM henvalt.shopify_connections WHERE shop_domain='store-b.myshopify.com';
  IF v_store_a IS NULL OR v_store_b IS NULL THEN
    RAISE EXCEPTION 'Checkout V2 test requires the two synthetic stores';
  END IF;

  INSERT INTO henvalt.shopify_webhook_route_tokens (
    tenant_id, connection_id, app_key, token_hash
  )
  VALUES (
    v_tenant, v_store_b, 'test_app',
    encode(extensions.digest(convert_to(v_token_b,'UTF8'),'sha256'),'hex')
  );

  v_hmac := encode(
    extensions.hmac(convert_to(v_body_a,'UTF8'),convert_to('synthetic-test-secret-never-used-in-production','UTF8'),'sha256'),
    'base64'
  );
  SELECT * INTO v_result FROM henvalt.accept_shopify_webhook_v2(
    v_token_a,v_hmac,encode(convert_to(v_body_a,'UTF8'),'base64'),
    'store-a.myshopify.com','checkouts/create','checkout-delivery-a','checkout-event-a'
  );
  IF v_result.accepted IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'Store A checkout webhook was not verified: %',row_to_json(v_result);
  END IF;

  v_projection := henvalt.project_verified_shopify_checkout_v2(
    v_token_a,'checkout-delivery-a',encode(convert_to(v_body_a,'UTF8'),'base64')
  );
  IF v_projection->>'accepted'<>'true' OR v_projection->>'status'<>'PROCESSED' THEN
    RAISE EXCEPTION 'Store A checkout projection failed: %',v_projection;
  END IF;

  -- The preceding pixel regression deliberately deactivated Store B; restore it
  -- here so this adapter test exercises an active installation.
  UPDATE henvalt.shopify_connections SET active=true WHERE id IN (v_store_a,v_store_b);

  v_hmac := encode(
    extensions.hmac(convert_to(v_body_b,'UTF8'),convert_to('synthetic-test-secret-never-used-in-production','UTF8'),'sha256'),
    'base64'
  );
  SELECT * INTO v_result FROM henvalt.accept_shopify_webhook_v2(
    v_token_b,v_hmac,encode(convert_to(v_body_b,'UTF8'),'base64'),
    'store-b.myshopify.com','checkouts/update','checkout-delivery-b','checkout-event-b'
  );
  IF v_result.accepted IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'Store B checkout webhook was not verified: %',row_to_json(v_result);
  END IF;

  v_projection := henvalt.project_verified_shopify_checkout_v2(
    v_token_b,'checkout-delivery-b',encode(convert_to(v_body_b,'UTF8'),'base64')
  );
  IF v_projection->>'accepted'<>'true' OR v_projection->>'status'<>'PROCESSED' THEN
    RAISE EXCEPTION 'Store B checkout projection failed: %',v_projection;
  END IF;

  SELECT count(*) INTO v_a_count FROM henvalt.shopify_checkout_identity_v2
  WHERE shopify_connection_id=v_store_a AND shopify_checkout_token='shared-checkout-token'
    AND total_value=125.50 AND currency='USD';
  SELECT count(*) INTO v_b_count FROM henvalt.shopify_checkout_identity_v2
  WHERE shopify_connection_id=v_store_b AND shopify_checkout_token='shared-checkout-token'
    AND total_value=75.00 AND currency='GBP';
  IF v_a_count<>1 OR v_b_count<>1 THEN
    RAISE EXCEPTION 'Same checkout token was not isolated by store: A %, B %',v_a_count,v_b_count;
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM henvalt.shopify_checkout_identity_v2 c
    JOIN henvalt.shopify_customer_identity_v2 cu
      ON cu.id=c.customer_identity_id
     AND cu.tenant_id=c.tenant_id
     AND cu.shopify_connection_id=c.shopify_connection_id
    WHERE c.shopify_connection_id=v_store_a
      AND c.shopify_checkout_token='shared-checkout-token'
      AND cu.external_customer_reference='12345'
  ) OR NOT EXISTS (
    SELECT 1 FROM henvalt.shopify_checkout_identity_v2 c
    JOIN henvalt.shopify_customer_identity_v2 cu
      ON cu.id=c.customer_identity_id
     AND cu.tenant_id=c.tenant_id
     AND cu.shopify_connection_id=c.shopify_connection_id
    WHERE c.shopify_connection_id=v_store_b
      AND c.shopify_checkout_token='shared-checkout-token'
      AND cu.external_customer_reference='12345'
  ) THEN
    RAISE EXCEPTION 'Checkout customer identity was not scoped to its exact store';
  END IF;

  -- Exact same delivery retry is idempotent and keeps one checkout identity.
  v_projection := henvalt.project_verified_shopify_checkout_v2(
    v_token_a,'checkout-delivery-a',encode(convert_to(v_body_a,'UTF8'),'base64')
  );
  IF v_projection->>'accepted'<>'true' THEN
    RAISE EXCEPTION 'Checkout projection retry failed: %',v_projection;
  END IF;
  SELECT count(*) INTO v_a_count FROM henvalt.shopify_checkout_identity_v2
  WHERE shopify_connection_id=v_store_a AND shopify_checkout_token='shared-checkout-token';
  IF v_a_count<>1 THEN
    RAISE EXCEPTION 'Checkout retry created duplicate identity rows';
  END IF;

  -- Shopify may deliver checkout updates out of order. The newest source
  -- updated_at wins; an older delivery is acknowledged but cannot regress state.
  v_body_a := '{"shop_id":"1001","token":"shared-checkout-token","customer":{"id":12345},"total_price":"200.00","currency":"USD","completed_at":null,"updated_at":"2026-11-19T12:00:00Z"}';
  v_hmac := encode(extensions.hmac(convert_to(v_body_a,'UTF8'),convert_to('synthetic-test-secret-never-used-in-production','UTF8'),'sha256'),'base64');
  SELECT * INTO v_result FROM henvalt.accept_shopify_webhook_v2(v_token_a,v_hmac,encode(convert_to(v_body_a,'UTF8'),'base64'),'store-a.myshopify.com','checkouts/update','checkout-delivery-newer','checkout-event-newer');
  v_projection := henvalt.project_verified_shopify_checkout_v2(v_token_a,'checkout-delivery-newer',encode(convert_to(v_body_a,'UTF8'),'base64'));
  IF v_projection->>'status'<>'PROCESSED' THEN RAISE EXCEPTION 'Newer checkout update was not applied: %',v_projection; END IF;

  v_body_a := '{"shop_id":"1001","token":"shared-checkout-token","customer":{"id":12345},"total_price":"150.00","currency":"USD","completed_at":null,"updated_at":"2026-11-19T11:00:00Z"}';
  v_hmac := encode(extensions.hmac(convert_to(v_body_a,'UTF8'),convert_to('synthetic-test-secret-never-used-in-production','UTF8'),'sha256'),'base64');
  SELECT * INTO v_result FROM henvalt.accept_shopify_webhook_v2(v_token_a,v_hmac,encode(convert_to(v_body_a,'UTF8'),'base64'),'store-a.myshopify.com','checkouts/update','checkout-delivery-older','checkout-event-older');
  v_projection := henvalt.project_verified_shopify_checkout_v2(v_token_a,'checkout-delivery-older',encode(convert_to(v_body_a,'UTF8'),'base64'));
  IF v_projection->>'status'<>'STALE_EVENT_IGNORED' THEN RAISE EXCEPTION 'Out-of-order checkout update was not rejected: %',v_projection; END IF;
  IF NOT EXISTS (SELECT 1 FROM henvalt.shopify_checkout_identity_v2 WHERE shopify_connection_id=v_store_a AND shopify_checkout_token='shared-checkout-token' AND total_value=200.00 AND source_updated_at='2026-11-19T12:00:00Z'::timestamptz) THEN
    RAISE EXCEPTION 'Older checkout webhook regressed the newer projection';
  END IF;

  -- A body not matching the verified receipt cannot be projected.
  v_projection := henvalt.project_verified_shopify_checkout_v2(
    v_token_a,'checkout-delivery-a',encode(convert_to(v_body_b,'UTF8'),'base64')
  );
  IF v_projection->>'accepted'<>'false' OR v_projection->>'code'<>'RECEIPT_BODY_MISMATCH' THEN
    RAISE EXCEPTION 'Unverified replacement body was projected: %',v_projection;
  END IF;

  -- Missing required checkout token is durably quarantined, never inserted.
  v_body_a := '{"shop_id":"1001","customer":{"id":12345},"total_price":"99.00","currency":"USD"}';
  v_hmac := encode(
    extensions.hmac(convert_to(v_body_a,'UTF8'),convert_to('synthetic-test-secret-never-used-in-production','UTF8'),'sha256'),
    'base64'
  );
  SELECT * INTO v_result FROM henvalt.accept_shopify_webhook_v2(
    v_token_a,v_hmac,encode(convert_to(v_body_a,'UTF8'),'base64'),
    'store-a.myshopify.com','checkouts/create','checkout-delivery-no-token','checkout-event-no-token'
  );
  v_projection := henvalt.project_verified_shopify_checkout_v2(
    v_token_a,'checkout-delivery-no-token',encode(convert_to(v_body_a,'UTF8'),'base64')
  );
  IF v_projection->>'accepted'<>'true' OR v_projection->>'status'<>'REVIEW_REQUIRED'
     OR NOT EXISTS (
       SELECT 1 FROM henvalt.shopify_webhook_deliveries
       WHERE shopify_delivery_id='checkout-delivery-no-token'
         AND processing_status='REJECTED'
         AND failure_code='CHECKOUT_TOKEN_MISSING'
     ) THEN
    RAISE EXCEPTION 'Missing checkout token was not quarantined: %',v_projection;
  END IF;
END;
$checkout_v2$;

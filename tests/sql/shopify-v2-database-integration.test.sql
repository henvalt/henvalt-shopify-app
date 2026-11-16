-- Integration tests for migrations 001-006 on a disposable PostgreSQL instance.
\set ON_ERROR_STOP on

INSERT INTO vault.secrets (name, secret)
VALUES ('test-shopify-secret', 'synthetic-test-secret-never-used-in-production');

INSERT INTO henvalt.shopify_app_registry (
  app_key, shopify_client_id, webhook_secret_ref, distribution_class, lifecycle_status
)
VALUES ('test_app', 'test-client-id', 'test-shopify-secret', 'test', 'active');

INSERT INTO henvalt.shopify_oauth_states (
  state_hash, shop_domain, expires_at, initiated_by_user_id, app_key
)
VALUES (
  'synthetic-state-hash',
  'store-a.myshopify.com',
  now() + interval '10 minutes',
  '00000000-0000-4000-8000-000000000001',
  'test_app'
);

DO $test$
DECLARE
  v_finalized jsonb;
  v_identity jsonb;
  v_connection_id uuid;
  v_second_connection_id uuid;
  v_route_token text := repeat('a', 64);
  v_rotated_route_token text := repeat('b', 64);
  v_rotated_finalized jsonb;
  v_body text := '{"shop_domain":"store-a.myshopify.com","shop_id":"1001"}';
  v_hmac text;
  v_changed_body text := '{"shop_domain":"store-a.myshopify.com","shop_id":"1001","changed":true}';
  v_changed_hmac text;
  v_result record;
  v_privacy_body text := '{"shop_domain":"store-a.myshopify.com","shop_id":"1001","customer":{"id":12345},"data_request":{"id":98765}}';
  v_privacy_hmac text;
  v_changed_privacy_body text := '{"shop_domain":"store-a.myshopify.com","shop_id":"1001","customer":{"id":12345},"data_request":{"id":98765},"changed":true}';
  v_changed_privacy_hmac text;
  v_second_shop_body text := '{"shop_domain":"store-b.myshopify.com","shop_id":"2002","customer":{"id":12345},"data_request":{"id":98765}}';
  v_second_shop_hmac text;
  v_wrong_shop_id_body text := '{"shop_domain":"store-b.myshopify.com","shop_id":"1001","customer":{"id":12345},"data_request":{"id":98765}}';
  v_wrong_shop_id_hmac text;
BEGIN
  v_finalized := henvalt.control_plane_finalize_shopify_oauth_install_app_aware(
    'synthetic-state-hash',
    'store-a.myshopify.com',
    repeat('x', 40),
    repeat('r', 40),
    3600,
    86400,
    '1001',
    ARRAY['read_orders']::text[],
    '00000000-0000-4000-8000-000000000001'::uuid,
    'test_app',
    'test-client-id',
    v_route_token
  );

  IF v_finalized->>'installed' <> 'true'
     OR v_finalized->>'webhook_route_ready' <> 'true'
     OR v_finalized->>'app_key' <> 'test_app' THEN
    RAISE EXCEPTION 'app-aware OAuth finalizer returned unexpected result: %', v_finalized;
  END IF;

  v_connection_id := (v_finalized->>'connection_id')::uuid;

  v_identity := henvalt.resolve_shopify_app_oauth_identity('test-client-id');
  IF v_identity->>'app_key' <> 'test_app'
     OR v_identity->>'shopify_client_id' <> 'test-client-id'
     OR v_identity->>'shopify_api_secret' <> 'synthetic-test-secret-never-used-in-production' THEN
    RAISE EXCEPTION 'App OAuth identity resolver returned an unexpected synthetic identity';
  END IF;

  INSERT INTO henvalt.shopify_connections (
    tenant_id, shop_domain, shopify_shop_id, active, app_key
  )
  VALUES (
    (v_finalized->>'tenant_id')::uuid,
    'store-b.myshopify.com',
    '2002',
    true,
    'test_app'
  )
  RETURNING id INTO v_second_connection_id;

  IF NOT EXISTS (
    SELECT 1 FROM henvalt.shopify_connections
    WHERE id = v_connection_id AND app_key = 'test_app'
      AND shop_domain = 'store-a.myshopify.com'
  ) THEN
    RAISE EXCEPTION 'OAuth finalizer did not bind the exact connection';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM henvalt.shopify_webhook_route_tokens
    WHERE connection_id = v_connection_id
      AND token_hash = encode(extensions.digest(convert_to(v_route_token, 'UTF8'), 'sha256'), 'hex')
      AND revoked_at IS NULL
  ) THEN
    RAISE EXCEPTION 'OAuth finalizer did not store the route token hash';
  END IF;

  IF EXISTS (
    SELECT 1 FROM henvalt.shopify_webhook_route_tokens
    WHERE token_hash = v_route_token
  ) THEN
    RAISE EXCEPTION 'Raw route token was persisted';
  END IF;

  v_hmac := encode(
    extensions.hmac(convert_to(v_body, 'UTF8'), convert_to('synthetic-test-secret-never-used-in-production', 'UTF8'), 'sha256'),
    'base64'
  );

  SELECT * INTO v_result
  FROM henvalt.accept_shopify_webhook_v2(
    v_route_token, v_hmac,
    encode(convert_to(v_body, 'UTF8'), 'base64'),
    'store-a.myshopify.com', 'orders/create', 'delivery-001', 'event-001'
  );

  IF v_result.accepted IS DISTINCT FROM true OR v_result.duplicate IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'First webhook was not accepted as a new receipt: %', row_to_json(v_result);
  END IF;

  SELECT * INTO v_result
  FROM henvalt.accept_shopify_webhook_v2(
    v_route_token, v_hmac,
    encode(convert_to(v_body, 'UTF8'), 'base64'),
    'store-a.myshopify.com', 'orders/create', 'delivery-001', 'event-001'
  );

  IF v_result.accepted IS DISTINCT FROM true OR v_result.duplicate IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'Duplicate webhook was not idempotently acknowledged: %', row_to_json(v_result);
  END IF;

  v_changed_hmac := encode(
    extensions.hmac(convert_to(v_changed_body, 'UTF8'), convert_to('synthetic-test-secret-never-used-in-production', 'UTF8'), 'sha256'),
    'base64'
  );
  SELECT * INTO v_result
  FROM henvalt.accept_shopify_webhook_v2(
    v_route_token, v_changed_hmac,
    encode(convert_to(v_changed_body, 'UTF8'), 'base64'),
    'store-a.myshopify.com', 'orders/create', 'delivery-001', 'event-001'
  );
  IF v_result.accepted IS DISTINCT FROM false OR v_result.rejection_code <> 'DELIVERY_ID_BODY_MISMATCH' THEN
    RAISE EXCEPTION 'Webhook delivery ID reuse with changed body was not rejected: %', row_to_json(v_result);
  END IF;

  INSERT INTO henvalt.shopify_oauth_states (
    state_hash, shop_domain, expires_at, initiated_by_user_id, app_key
  )
  VALUES (
    'synthetic-state-hash-2',
    'store-a.myshopify.com',
    now() + interval '10 minutes',
    '00000000-0000-4000-8000-000000000001',
    'test_app'
  );

  v_rotated_finalized := henvalt.control_plane_finalize_shopify_oauth_install_app_aware(
    'synthetic-state-hash-2',
    'store-a.myshopify.com',
    repeat('y', 40),
    repeat('s', 40),
    3600,
    86400,
    '1001',
    ARRAY['read_orders']::text[],
    '00000000-0000-4000-8000-000000000001'::uuid,
    'test_app',
    'test-client-id',
    v_rotated_route_token
  );

  IF NOT EXISTS (
    SELECT 1 FROM henvalt.shopify_webhook_route_tokens
    WHERE connection_id = v_connection_id
      AND token_hash = encode(extensions.digest(convert_to(v_route_token, 'UTF8'), 'sha256'), 'hex')
      AND revoked_at IS NOT NULL
  ) OR NOT EXISTS (
    SELECT 1 FROM henvalt.shopify_webhook_route_tokens
    WHERE connection_id = v_connection_id
      AND token_hash = encode(extensions.digest(convert_to(v_rotated_route_token, 'UTF8'), 'sha256'), 'hex')
      AND revoked_at IS NULL
  ) THEN
    RAISE EXCEPTION 'OAuth reauthorization did not rotate the per-install route token';
  END IF;

  SELECT * INTO v_result
  FROM henvalt.accept_shopify_webhook_v2(
    v_route_token, v_hmac,
    encode(convert_to(v_body, 'UTF8'), 'base64'),
    'store-a.myshopify.com', 'orders/create', 'delivery-after-rotation-old', 'event-after-rotation-old'
  );

  IF v_result.accepted IS DISTINCT FROM false OR v_result.rejection_code <> 'ROUTE_TOKEN_INVALID' THEN
    RAISE EXCEPTION 'Revoked route token remained usable after reauthorization';
  END IF;

  SELECT * INTO v_result
  FROM henvalt.accept_shopify_webhook_v2(
    v_rotated_route_token, v_hmac,
    encode(convert_to(v_body, 'UTF8'), 'base64'),
    'store-a.myshopify.com', 'orders/create', 'delivery-after-rotation-new', 'event-after-rotation-new'
  );

  IF v_result.accepted IS DISTINCT FROM true OR v_result.duplicate IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'New route token did not accept webhook after reauthorization';
  END IF;

  v_privacy_hmac := encode(
    extensions.hmac(convert_to(v_privacy_body, 'UTF8'), convert_to('synthetic-test-secret-never-used-in-production', 'UTF8'), 'sha256'),
    'base64'
  );

  SELECT * INTO v_result
  FROM henvalt.accept_shopify_privacy_webhook_v2(
    'test_app', 'test-client-id', v_privacy_hmac,
    encode(convert_to(v_privacy_body, 'UTF8'), 'base64'),
    'store-a.myshopify.com', 'customers/data_request', 'privacy-delivery-001'
  );

  IF v_result.accepted IS DISTINCT FROM true
     OR v_result.receipt_status <> 'REVIEW_REQUIRED'
     OR v_result.duplicate IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'Privacy request was not durably queued for review: %', row_to_json(v_result);
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM henvalt.shopify_privacy_webhook_deliveries
    WHERE app_key = 'test_app'
      AND connection_id = v_connection_id
      AND shop_domain = 'store-a.myshopify.com'
      AND customer_id = '12345'
      AND request_id = '98765'
      AND processing_status = 'REVIEW_REQUIRED'
  ) THEN
    RAISE EXCEPTION 'Privacy receipt was not linked to exact store or review-gated';
  END IF;

  SELECT * INTO v_result
  FROM henvalt.accept_shopify_privacy_webhook_v2(
    'test_app', 'test-client-id', v_privacy_hmac,
    encode(convert_to(v_privacy_body, 'UTF8'), 'base64'),
    'store-a.myshopify.com', 'customers/data_request', 'privacy-delivery-001'
  );

  IF v_result.accepted IS DISTINCT FROM true OR v_result.duplicate IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'Duplicate privacy webhook was not idempotently acknowledged';
  END IF;

  v_changed_privacy_hmac := encode(
    extensions.hmac(convert_to(v_changed_privacy_body, 'UTF8'), convert_to('synthetic-test-secret-never-used-in-production', 'UTF8'), 'sha256'),
    'base64'
  );
  SELECT * INTO v_result
  FROM henvalt.accept_shopify_privacy_webhook_v2(
    'test_app', 'test-client-id', v_changed_privacy_hmac,
    encode(convert_to(v_changed_privacy_body, 'UTF8'), 'base64'),
    'store-a.myshopify.com', 'customers/data_request', 'privacy-delivery-001'
  );
  IF v_result.accepted IS DISTINCT FROM false OR v_result.rejection_code <> 'DELIVERY_ID_BODY_MISMATCH' THEN
    RAISE EXCEPTION 'Privacy delivery ID reuse with changed body was not rejected: %', row_to_json(v_result);
  END IF;

  -- A shared tenant may contain two stores. The same webhook ID in Store B
  -- must create a separate receipt, bound to Store B rather than Store A.
  v_second_shop_hmac := encode(
    extensions.hmac(convert_to(v_second_shop_body, 'UTF8'), convert_to('synthetic-test-secret-never-used-in-production', 'UTF8'), 'sha256'),
    'base64'
  );

  SELECT * INTO v_result
  FROM henvalt.accept_shopify_privacy_webhook_v2(
    'test_app', 'test-client-id', v_second_shop_hmac,
    encode(convert_to(v_second_shop_body, 'UTF8'), 'base64'),
    'store-b.myshopify.com', 'customers/data_request', 'privacy-delivery-001'
  );

  IF v_result.accepted IS DISTINCT FROM true OR v_result.duplicate IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'Store B privacy receipt collided with Store A delivery identity: %', row_to_json(v_result);
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM henvalt.shopify_privacy_webhook_deliveries
    WHERE app_key = 'test_app'
      AND shop_domain = 'store-b.myshopify.com'
      AND webhook_id = 'privacy-delivery-001'
      AND connection_id = v_second_connection_id
  ) THEN
    RAISE EXCEPTION 'Store B privacy receipt was not bound to Store B connection';
  END IF;

  v_wrong_shop_id_hmac := encode(
    extensions.hmac(convert_to(v_wrong_shop_id_body, 'UTF8'), convert_to('synthetic-test-secret-never-used-in-production', 'UTF8'), 'sha256'),
    'base64'
  );

  SELECT * INTO v_result
  FROM henvalt.accept_shopify_privacy_webhook_v2(
    'test_app', 'test-client-id', v_wrong_shop_id_hmac,
    encode(convert_to(v_wrong_shop_id_body, 'UTF8'), 'base64'),
    'store-b.myshopify.com', 'customers/data_request', 'privacy-delivery-wrong-shop-id'
  );

  IF v_result.accepted IS DISTINCT FROM false OR v_result.rejection_code <> 'SHOP_ID_MISMATCH' THEN
    RAISE EXCEPTION 'Privacy webhook with another store ID was not rejected: %', row_to_json(v_result);
  END IF;

  SELECT * INTO v_result
  FROM henvalt.accept_shopify_privacy_webhook_v2(
    'test_app', 'test-client-id', encode(decode(repeat('00', 32), 'hex'), 'base64'),
    encode(convert_to(v_privacy_body, 'UTF8'), 'base64'),
    'store-a.myshopify.com', 'customers/data_request', 'privacy-delivery-002'
  );

  IF v_result.accepted IS DISTINCT FROM false OR v_result.rejection_code <> 'HMAC_INVALID' THEN
    RAISE EXCEPTION 'Invalid privacy HMAC was not rejected: %', row_to_json(v_result);
  END IF;

  IF has_function_privilege('anon', 'henvalt.accept_shopify_privacy_webhook_v2(text,text,text,text,text,text,text)', 'EXECUTE') THEN
    RAISE EXCEPTION 'Anonymous role can execute the privacy RPC';
  END IF;
  IF NOT has_function_privilege('service_role', 'henvalt.accept_shopify_privacy_webhook_v2(text,text,text,text,text,text,text)', 'EXECUTE') THEN
    RAISE EXCEPTION 'service_role cannot execute the privacy RPC';
  END IF;
END;
$test$;

SELECT 'shopify_v2_database_integration_passed' AS result;

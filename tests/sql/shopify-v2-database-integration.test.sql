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


-- Exact-store lineage foundation integration checks (migration 007).
DO $lineage$
DECLARE
  v_tenant uuid := '00000000-0000-4000-8000-000000000001';
  v_store_a uuid;
  v_store_b uuid;
  v_customer_a uuid;
  v_session_a uuid;
  v_checkout_a uuid;
  v_event_a uuid;
BEGIN
  SELECT id INTO v_store_a FROM henvalt.shopify_connections WHERE shop_domain='store-a.myshopify.com';
  SELECT id INTO v_store_b FROM henvalt.shopify_connections WHERE shop_domain='store-b.myshopify.com';

  IF v_store_a IS NULL OR v_store_b IS NULL THEN
    RAISE EXCEPTION 'Two-store synthetic connections were not created';
  END IF;

  INSERT INTO henvalt.customers (tenant_id, shopify_customer_id, email, shopify_connection_id)
  VALUES (v_tenant, 'shared-shopify-customer-id', 'same@example.invalid', v_store_a)
  RETURNING id INTO v_customer_a;

  INSERT INTO henvalt.sessions (tenant_id, customer_id, session_reference, shopify_connection_id)
  VALUES (v_tenant, v_customer_a, 'shared-session-ref', v_store_a)
  RETURNING id INTO v_session_a;

  INSERT INTO henvalt.session_aliases (tenant_id, alias_reference, session_reference, shopify_connection_id)
  VALUES (v_tenant, 'store-a-cart-alias', 'shared-session-ref', v_store_a);

  INSERT INTO henvalt.checkouts (tenant_id, customer_id, shopify_checkout_id, checkout_token, session_reference, email, shopify_connection_id)
  VALUES (v_tenant, v_customer_a, 'store-a-checkout', 'store-a-token', 'shared-session-ref', 'same@example.invalid', v_store_a)
  RETURNING id INTO v_checkout_a;

  INSERT INTO henvalt.canonical_events (tenant_id, event_type, event_class, source, session_reference, idempotency_key, shopify_connection_id)
  VALUES (v_tenant, 'PRODUCT_VIEWED', 'OTHER', 'SHOPIFY_WEB_PIXEL', 'shared-session-ref', 'pixel:' || v_store_a::text || ':event-1', v_store_a)
  RETURNING id INTO v_event_a;

  IF NOT EXISTS (SELECT 1 FROM henvalt.customers WHERE id=v_customer_a AND shopify_connection_id=v_store_a)
     OR NOT EXISTS (SELECT 1 FROM henvalt.sessions WHERE id=v_session_a AND shopify_connection_id=v_store_a)
     OR NOT EXISTS (SELECT 1 FROM henvalt.checkouts WHERE id=v_checkout_a AND shopify_connection_id=v_store_a)
     OR NOT EXISTS (SELECT 1 FROM henvalt.canonical_events WHERE id=v_event_a AND shopify_connection_id=v_store_a) THEN
    RAISE EXCEPTION 'Exact-store lineage was not persisted on all core records';
  END IF;

  BEGIN
    INSERT INTO henvalt.checkouts (tenant_id, customer_id, shopify_checkout_id, shopify_connection_id)
    VALUES (v_tenant, v_customer_a, 'wrong-store-checkout', v_store_b);
    RAISE EXCEPTION 'Cross-store customer reference was unexpectedly accepted';
  EXCEPTION WHEN foreign_key_violation THEN
    NULL;
  END;

  BEGIN
    INSERT INTO henvalt.session_aliases (tenant_id, alias_reference, session_reference, shopify_connection_id)
    VALUES (v_tenant, 'store-b-alias-to-a', 'shared-session-ref', v_store_b);
    RAISE EXCEPTION 'Cross-store session alias was unexpectedly accepted';
  EXCEPTION WHEN foreign_key_violation THEN
    NULL;
  END;

  BEGIN
    INSERT INTO henvalt.customers (tenant_id, shopify_customer_id, email, shopify_connection_id)
    VALUES (v_tenant, 'shared-shopify-customer-id', 'same@example.invalid', v_store_b);
    RAISE EXCEPTION 'Legacy tenant-only customer uniqueness was unexpectedly removed';
  EXCEPTION WHEN unique_violation THEN
    NULL;
  END;

  INSERT INTO henvalt.customers (tenant_id, shopify_customer_id, email)
  VALUES (v_tenant, 'legacy-unresolved-customer', 'legacy@example.invalid');

  IF NOT EXISTS (
    SELECT 1 FROM henvalt.customers
    WHERE tenant_id=v_tenant
      AND shopify_customer_id='legacy-unresolved-customer'
      AND shopify_connection_id IS NULL
  ) THEN
    RAISE EXCEPTION 'Legacy unresolved row was unexpectedly assigned a store';
  END IF;
END;
$lineage$;


-- Connection-aware Web Pixel V2 inbox integration checks (migration 008).
DO $pixel_v2$
DECLARE
  v_tenant uuid := '00000000-0000-4000-8000-000000000001';
  v_store_a uuid;
  v_store_b uuid;
  v_result jsonb;
  v_payload_a jsonb;
  v_payload_b jsonb;
  v_changed_payload jsonb;
  v_payload_no_consent jsonb;
  v_inbox_a uuid;
  v_inbox_b uuid;
  v_canonical_before bigint;
  v_customers_before bigint;
  v_sessions_before bigint;
  v_aliases_before bigint;
  v_checkouts_before bigint;
BEGIN
  INSERT INTO henvalt.tenants (id, status)
  VALUES (v_tenant, 'ACTIVE')
  ON CONFLICT (id) DO UPDATE SET status = 'ACTIVE';

  SELECT id INTO v_store_a FROM henvalt.shopify_connections WHERE shop_domain='store-a.myshopify.com';
  SELECT id INTO v_store_b FROM henvalt.shopify_connections WHERE shop_domain='store-b.myshopify.com';

  IF v_store_a IS NULL OR v_store_b IS NULL THEN
    RAISE EXCEPTION 'Pixel V2 test requires two synthetic stores';
  END IF;

  SELECT count(*) INTO v_canonical_before FROM henvalt.canonical_events WHERE source='SHOPIFY_WEB_PIXEL';
  SELECT count(*) INTO v_customers_before FROM henvalt.customers;
  SELECT count(*) INTO v_sessions_before FROM henvalt.sessions;
  SELECT count(*) INTO v_aliases_before FROM henvalt.session_aliases;
  SELECT count(*) INTO v_checkouts_before FROM henvalt.checkouts;

  INSERT INTO henvalt.pixel_keys (tenant_id, key_digest, allowed_origins, active, revoked_at, shopify_connection_id)
  VALUES
    (v_tenant, repeat('a', 64), ARRAY['https://store-a.example'], true, NULL, v_store_a),
    (v_tenant, repeat('b', 64), ARRAY['https://store-b.example'], true, NULL, v_store_b);

  v_payload_a := jsonb_build_object(
    'schema_version','1',
    'event_type','checkout_started',
    'event_id','shared-pixel-event-id',
    'client_id','shared-client-reference',
    'customer_reference','shared-shopify-customer-id',
    'checkout_reference','shared-checkout-alias',
    'analytics_consent','true',
    'marketing_consent','false',
    'occurred_at',now()
  );

  v_payload_b := v_payload_a;

  v_result := henvalt.ingest_pixel_event_v2(repeat('a',64), 'https://store-a.example', v_payload_a);
  IF v_result->>'accepted' <> 'true' OR v_result->>'duplicate' <> 'false'
     OR v_result->>'status' <> 'PENDING_ADAPTER' THEN
    RAISE EXCEPTION 'Store A pixel event was not accepted into the isolated inbox: %', v_result;
  END IF;
  v_inbox_a := (v_result->>'inbox_id')::uuid;

  v_result := henvalt.ingest_pixel_event_v2(repeat('b',64), 'https://store-b.example', v_payload_b);
  IF v_result->>'accepted' <> 'true' OR v_result->>'duplicate' <> 'false' THEN
    RAISE EXCEPTION 'Same event ID in Store B collided with Store A: %', v_result;
  END IF;
  v_inbox_b := (v_result->>'inbox_id')::uuid;

  IF v_inbox_a = v_inbox_b
     OR NOT EXISTS (SELECT 1 FROM henvalt.shopify_pixel_event_inbox_v2 WHERE id=v_inbox_a AND shopify_connection_id=v_store_a)
     OR NOT EXISTS (SELECT 1 FROM henvalt.shopify_pixel_event_inbox_v2 WHERE id=v_inbox_b AND shopify_connection_id=v_store_b) THEN
    RAISE EXCEPTION 'Pixel inbox events were not isolated by exact Shopify connection';
  END IF;

  v_result := henvalt.ingest_pixel_event_v2(repeat('a',64), 'https://store-a.example', v_payload_a);
  IF v_result->>'accepted' <> 'true' OR v_result->>'duplicate' <> 'true' THEN
    RAISE EXCEPTION 'Exact Store A retry was not idempotent: %', v_result;
  END IF;

  v_changed_payload := v_payload_a || jsonb_build_object('marketing_consent','true');
  v_result := henvalt.ingest_pixel_event_v2(repeat('a',64), 'https://store-a.example', v_changed_payload);
  IF v_result->>'accepted' <> 'false' OR v_result->>'rejection_code' <> 'EVENT_ID_BODY_MISMATCH' THEN
    RAISE EXCEPTION 'Changed payload reusing Store A event ID was not rejected: %', v_result;
  END IF;

  v_payload_no_consent := jsonb_build_object(
    'schema_version','1',
    'event_type','product_viewed',
    'event_id','no-consent-event',
    'client_id','must-not-be-stored',
    'customer_reference','must-not-be-stored',
    'checkout_reference','must-not-be-stored',
    'analytics_consent','false',
    'marketing_consent','true',
    'occurred_at',now()
  );
  v_result := henvalt.ingest_pixel_event_v2(repeat('a',64), 'https://store-a.example', v_payload_no_consent);
  IF v_result->>'accepted' <> 'true' THEN
    RAISE EXCEPTION 'No-consent event should be received without identity fields: %', v_result;
  END IF;

  IF EXISTS (
    SELECT 1 FROM henvalt.shopify_pixel_event_inbox_v2
    WHERE source_event_id='no-consent-event'
      AND (client_reference IS NOT NULL OR customer_reference IS NOT NULL OR checkout_reference IS NOT NULL
        OR payload ? 'client_id' OR payload ? 'customer_reference' OR payload ? 'checkout_reference')
  ) THEN
    RAISE EXCEPTION 'Analytics-disabled event persisted identity-bearing fields';
  END IF;

  IF (SELECT count(*) FROM henvalt.canonical_events WHERE source='SHOPIFY_WEB_PIXEL') <> v_canonical_before
     OR (SELECT count(*) FROM henvalt.customers) <> v_customers_before
     OR (SELECT count(*) FROM henvalt.sessions) <> v_sessions_before
     OR (SELECT count(*) FROM henvalt.session_aliases) <> v_aliases_before
     OR (SELECT count(*) FROM henvalt.checkouts) <> v_checkouts_before THEN
    RAISE EXCEPTION 'Pixel V2 inbox wrote into a legacy downstream identity/recovery table';
  END IF;

  UPDATE henvalt.pixel_keys SET revoked_at=now(), active=false WHERE key_digest=repeat('a',64);
  BEGIN
    PERFORM henvalt.ingest_pixel_event_v2(
      repeat('a',64),
      'https://store-a.example',
      v_payload_a || jsonb_build_object('event_id','revoked-key-event')
    );
    RAISE EXCEPTION 'Revoked pixel key was unexpectedly accepted';
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM = 'Revoked pixel key was unexpectedly accepted' THEN
      RAISE;
    END IF;
    IF SQLERRM NOT LIKE '%not authorized%' THEN
      RAISE;
    END IF;
  END;

  UPDATE henvalt.shopify_connections SET active=false WHERE id=v_store_b;
  BEGIN
    PERFORM henvalt.ingest_pixel_event_v2(
      repeat('b',64),
      'https://store-b.example',
      v_payload_b || jsonb_build_object('event_id','inactive-store-event')
    );
    RAISE EXCEPTION 'Inactive store key was unexpectedly accepted';
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM = 'Inactive store key was unexpectedly accepted' THEN
      RAISE;
    END IF;
    IF SQLERRM NOT LIKE '%not authorized%' THEN
      RAISE;
    END IF;
  END;

  IF has_function_privilege('anon', 'henvalt.ingest_pixel_event_v2(text,text,jsonb)', 'EXECUTE')
     OR has_function_privilege('authenticated', 'henvalt.ingest_pixel_event_v2(text,text,jsonb)', 'EXECUTE')
     OR NOT has_function_privilege('service_role', 'henvalt.ingest_pixel_event_v2(text,text,jsonb)', 'EXECUTE') THEN
    RAISE EXCEPTION 'Pixel V2 RPC privileges are not server-only';
  END IF;
END;
$pixel_v2$;


SELECT 'shopify_v2_database_integration_passed' AS result;

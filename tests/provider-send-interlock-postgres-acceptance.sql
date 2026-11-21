\set ON_ERROR_STOP on

DO $acceptance$
DECLARE
  v_id uuid;
  v_role text;
  v_events integer;
BEGIN
  IF henvalt.provider_sending_is_enabled() IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'default interlock is not closed';
  END IF;

  FOREACH v_role IN ARRAY ARRAY['anon', 'authenticated', 'service_role'] LOOP
    IF has_table_privilege(v_role, 'henvalt.provider_send_control', 'SELECT')
       OR has_table_privilege(v_role, 'henvalt.provider_send_control', 'UPDATE')
       OR has_table_privilege(v_role, 'henvalt.provider_send_control_events', 'SELECT')
       OR has_table_privilege(v_role, 'henvalt.provider_send_control_events', 'INSERT')
       OR has_function_privilege(v_role, 'henvalt.provider_sending_is_enabled()', 'EXECUTE')
       OR has_function_privilege(v_role, 'henvalt.set_provider_sending_enabled(boolean,text)', 'EXECUTE')
       OR has_function_privilege(v_role, 'henvalt.enforce_provider_send_interlock()', 'EXECUTE') THEN
      RAISE EXCEPTION 'application role % has unexpected interlock privileges', v_role;
    END IF;
  END LOOP;

  BEGIN
    INSERT INTO henvalt.delivery_requests(status) VALUES ('UNKNOWN');
    RAISE EXCEPTION 'expected direct UNKNOWN insert to be blocked';
  EXCEPTION WHEN insufficient_privilege THEN
    IF SQLERRM <> 'HENVALT_PROVIDER_SENDING_DISABLED' THEN RAISE; END IF;
  END;

  INSERT INTO henvalt.delivery_requests(status) VALUES ('PENDING') RETURNING id INTO v_id;
  BEGIN
    UPDATE henvalt.delivery_requests SET status = 'UNKNOWN' WHERE id = v_id;
    RAISE EXCEPTION 'expected PENDING to UNKNOWN transition to be blocked';
  EXCEPTION WHEN insufficient_privilege THEN
    IF SQLERRM <> 'HENVALT_PROVIDER_SENDING_DISABLED' THEN RAISE; END IF;
  END;

  BEGIN
    UPDATE henvalt.delivery_requests SET provider_claimed_at = now() WHERE id = v_id;
    RAISE EXCEPTION 'expected provider credential claim to be blocked';
  EXCEPTION WHEN insufficient_privilege THEN
    IF SQLERRM <> 'HENVALT_PROVIDER_SENDING_DISABLED' THEN RAISE; END IF;
  END;

  PERFORM henvalt.set_provider_sending_enabled(true, 'synthetic PostgreSQL staging integration test');
  INSERT INTO henvalt.delivery_requests(status) VALUES ('UNKNOWN') RETURNING id INTO v_id;

  PERFORM henvalt.set_provider_sending_enabled(false, 'close after synthetic staging integration test');
  IF henvalt.provider_sending_is_enabled() IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'interlock did not close after operator change';
  END IF;

  BEGIN
    UPDATE henvalt.delivery_requests SET status = 'UNKNOWN' WHERE id = v_id;
    RAISE EXCEPTION 'expected already-UNKNOWN update to be blocked after close';
  EXCEPTION WHEN insufficient_privilege THEN
    IF SQLERRM <> 'HENVALT_PROVIDER_SENDING_DISABLED' THEN RAISE; END IF;
  END;

  BEGIN
    UPDATE henvalt.delivery_requests SET provider_claimed_at = now() WHERE id = v_id;
    RAISE EXCEPTION 'expected provider credential claim to be blocked after close';
  EXCEPTION WHEN insufficient_privilege THEN
    IF SQLERRM <> 'HENVALT_PROVIDER_SENDING_DISABLED' THEN RAISE; END IF;
  END;

  DELETE FROM henvalt.provider_send_control WHERE control_key = 'global';
  IF henvalt.provider_sending_is_enabled() IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'missing control row did not fail closed';
  END IF;

  SELECT count(*) INTO v_events FROM henvalt.provider_send_control_events;
  IF v_events <> 2 THEN
    RAISE EXCEPTION 'expected two operator audit events, got %', v_events;
  END IF;
END
$acceptance$;

SELECT 'provider-send interlock PostgreSQL acceptance passed' AS result;


DO $pixel_acceptance$
DECLARE
  v_tenant uuid := gen_random_uuid();
  v_connection uuid := gen_random_uuid();
  v_customer uuid := gen_random_uuid();
  v_digest text := repeat('a', 64);
  v_origin text := 'https://store.example.com';
  v_result jsonb;
  v_candidates integer;
  v_source_event_id uuid;
  v_currency character(3);
BEGIN
  INSERT INTO henvalt.tenants(id, status) VALUES (v_tenant, 'ACTIVE');
  INSERT INTO henvalt.shopify_connections(id, tenant_id, active, shop_domain)
  VALUES (v_connection, v_tenant, true, 'synthetic.myshopify.com');
  INSERT INTO henvalt.pixel_keys(
    tenant_id, shopify_connection_id, key_digest, active, allowed_origins
  ) VALUES (
    v_tenant, v_connection, v_digest, true, ARRAY[v_origin]
  );
  INSERT INTO henvalt.customers(
    id, tenant_id, shopify_customer_id, email, email_consent
  ) VALUES (
    v_customer, v_tenant, '12345', 'synthetic@example.invalid', true
  );

  -- Server-side consent gate must reject before rate-limit or event persistence.
  v_result := henvalt.ingest_pixel_event(
    v_digest, v_origin,
    jsonb_build_object(
      'schema_version', 1,
      'event_id', 'no-analytics-consent',
      'event_type', 'product_viewed',
      'occurred_at', now()::text,
      'client_id', 'session-no-consent',
      'customer_reference', '12345',
      'analytics_consent', false,
      'marketing_consent', true,
      'page_url', 'https://store.example.com/products/widget',
      'product', jsonb_build_object('id', '100', 'title', 'Widget', 'price_amount', '19.99', 'price_currency', 'USD')
    )
  );
  IF v_result->>'accepted' <> 'false'
     OR v_result->>'error' <> 'analytics_consent_required' THEN
    RAISE EXCEPTION 'analytics consent false was not rejected: %', v_result;
  END IF;
  IF EXISTS (
    SELECT 1 FROM henvalt.canonical_events
    WHERE tenant_id = v_tenant AND source_event_id = 'no-analytics-consent'
  ) THEN
    RAISE EXCEPTION 'event persisted without analytics consent';
  END IF;
  IF EXISTS (SELECT 1 FROM henvalt.pixel_rate_limits WHERE key_digest = v_digest) THEN
    RAISE EXCEPTION 'rate-limit row was written for rejected no-consent event';
  END IF;

  -- Analytics is permitted, but marketing privacy permission is false.
  -- The events may be retained for analytics, but must not become recovery candidates.
  PERFORM henvalt.ingest_pixel_event(v_digest, v_origin, jsonb_build_object(
    'schema_version', 1, 'event_id', 'marketing-false-1',
    'event_type', 'product_viewed', 'occurred_at', (now() - interval '2 hours')::text,
    'client_id', 'session-marketing-false', 'customer_reference', '12345',
    'analytics_consent', true, 'marketing_consent', false,
    'page_url', 'https://store.example.com/products/widget',
    'product', jsonb_build_object('id', '100', 'title', 'Widget', 'variant_id', '200', 'price_amount', '19.99', 'price_currency', 'USD')
  ));
  PERFORM henvalt.ingest_pixel_event(v_digest, v_origin, jsonb_build_object(
    'schema_version', 1, 'event_id', 'marketing-false-2',
    'event_type', 'product_viewed', 'occurred_at', (now() - interval '90 minutes')::text,
    'client_id', 'session-marketing-false', 'customer_reference', '12345',
    'analytics_consent', true, 'marketing_consent', false,
    'page_url', 'https://store.example.com/products/widget',
    'product', jsonb_build_object('id', '100', 'title', 'Widget', 'variant_id', '200', 'price_amount', '19.99', 'price_currency', 'USD')
  ));
  SELECT count(*) INTO v_candidates
  FROM henvalt.get_browse_abandonment_candidates(60, 24, 100)
  WHERE tenant_id = v_tenant AND session_reference = 'session-marketing-false';
  IF v_candidates <> 0 THEN
    RAISE EXCEPTION 'browse recovery candidate created without marketing privacy permission';
  END IF;

  SELECT id INTO v_source_event_id
  FROM henvalt.canonical_events
  WHERE tenant_id = v_tenant AND source_event_id = 'marketing-false-2';
  IF NOT henvalt.browse_opportunity_advanced(
    v_tenant, 'session-marketing-false', v_source_event_id, NULL
  ) THEN
    RAISE EXCEPTION 'send-time browse guard did not suppress marketing-denied source event';
  END IF;

  -- With both analytics and marketing permission, repeat product views may
  -- become a browse-recovery candidate if customer email consent is also true.
  PERFORM henvalt.ingest_pixel_event(v_digest, v_origin, jsonb_build_object(
    'schema_version', 1, 'event_id', 'marketing-true-1',
    'event_type', 'product_viewed', 'occurred_at', (now() - interval '2 hours')::text,
    'client_id', 'session-marketing-true', 'customer_reference', '12345',
    'analytics_consent', true, 'marketing_consent', true,
    'page_url', 'https://store.example.com/products/widget',
    'product', jsonb_build_object('id', '100', 'title', 'Widget', 'variant_id', '200', 'price_amount', '19.99', 'price_currency', 'USD')
  ));
  PERFORM henvalt.ingest_pixel_event(v_digest, v_origin, jsonb_build_object(
    'schema_version', 1, 'event_id', 'marketing-true-2',
    'event_type', 'product_viewed', 'occurred_at', (now() - interval '90 minutes')::text,
    'client_id', 'session-marketing-true', 'customer_reference', '12345',
    'analytics_consent', true, 'marketing_consent', true,
    'page_url', 'https://store.example.com/products/widget',
    'product', jsonb_build_object('id', '100', 'title', 'Widget', 'variant_id', '200', 'price_amount', '19.99', 'price_currency', 'USD')
  ));
  SELECT count(*) INTO v_candidates
  FROM henvalt.get_browse_abandonment_candidates(60, 24, 100)
  WHERE tenant_id = v_tenant AND session_reference = 'session-marketing-true';
  IF v_candidates <> 1 THEN
    RAISE EXCEPTION 'expected one consent-eligible browse candidate, got %', v_candidates;
  END IF;

  SELECT currency INTO v_currency
  FROM henvalt.get_browse_abandonment_candidates(60, 24, 100)
  WHERE tenant_id = v_tenant AND session_reference = 'session-marketing-true';
  IF v_currency IS DISTINCT FROM 'USD'::character(3) OR length(v_currency) <> 3 THEN
    RAISE EXCEPTION 'browse candidate currency was truncated: %', v_currency;
  END IF;

  SELECT id INTO v_source_event_id
  FROM henvalt.canonical_events
  WHERE tenant_id = v_tenant AND source_event_id = 'marketing-true-2';
  IF henvalt.browse_opportunity_advanced(
    v_tenant, 'session-marketing-true', v_source_event_id, NULL
  ) THEN
    RAISE EXCEPTION 'send-time browse guard incorrectly suppressed consent-eligible source event';
  END IF;

  IF NOT henvalt.browse_opportunity_advanced(
    v_tenant, 'session-missing', gen_random_uuid(), now()
  ) THEN
    RAISE EXCEPTION 'missing source event did not fail closed';
  END IF;

  -- Product removal must pass the database event-type allowlist.
  v_result := henvalt.ingest_pixel_event(v_digest, v_origin, jsonb_build_object(
    'schema_version', 1, 'event_id', 'product-removed-1',
    'event_type', 'product_removed_from_cart', 'occurred_at', now()::text,
    'client_id', 'session-marketing-true', 'customer_reference', '12345',
    'analytics_consent', true, 'marketing_consent', true
  ));
  IF v_result->>'accepted' <> 'true' THEN
    RAISE EXCEPTION 'product_removed_from_cart was not accepted: %', v_result;
  END IF;
END
$pixel_acceptance$;


DO $dashboard_acceptance$
DECLARE
  v_tenant uuid := gen_random_uuid();
  v_connection uuid := gen_random_uuid();
  v_unconfirmed_opportunity uuid := gen_random_uuid();
  v_confirmed_opportunity uuid := gen_random_uuid();
  v_null_value_opportunity uuid := gen_random_uuid();
  v_order uuid := gen_random_uuid();
  v_null_value_order uuid := gen_random_uuid();
  v_summary jsonb;
BEGIN
  INSERT INTO henvalt.tenants(id, status, default_currency)
  VALUES (v_tenant, 'ACTIVE', 'USD');
  INSERT INTO henvalt.shopify_connections(id, tenant_id, active, shop_domain)
  VALUES (v_connection, v_tenant, true, 'dashboard-synthetic.myshopify.com');

  INSERT INTO henvalt.opportunities(
    id, tenant_id, created_at, updated_at, opportunity_type, status, value_at_risk, currency
  ) VALUES
    (v_unconfirmed_opportunity, v_tenant, now() - interval '1 hour', now(), 'ABANDONED_CHECKOUT', 'RECOVERED', 99.99, 'USD'),
    (v_confirmed_opportunity, v_tenant, now() - interval '2 hours', now(), 'ABANDONED_CHECKOUT', 'RECOVERED', 99.99, 'USD'),
    (v_null_value_opportunity, v_tenant, now() - interval '30 minutes', now(), 'ABANDONED_CHECKOUT', 'RECOVERED', 99.99, 'USD');

  INSERT INTO henvalt.recovery_interventions(
    tenant_id, opportunity_id, status, created_at, updated_at, delivered_at
  ) VALUES
    (v_tenant, v_unconfirmed_opportunity, 'DELIVERED', now() - interval '1 hour', now(), now()),
    (v_tenant, v_confirmed_opportunity, 'DELIVERED', now() - interval '2 hours', now(), now()),
    (v_tenant, v_null_value_opportunity, 'DELIVERED', now() - interval '30 minutes', now(), now());

  INSERT INTO henvalt.order_attributions(
    tenant_id, order_id, opportunity_id, attribution_confidence, attributed_value, evaluated_at
  ) VALUES (
    v_tenant, v_order, v_confirmed_opportunity, 'CONFIRMED', 45.67, now()
  );
  INSERT INTO henvalt.order_attributions(
    tenant_id, order_id, opportunity_id, attribution_confidence, attributed_value, evaluated_at
  ) VALUES (
    v_tenant, v_null_value_order, v_null_value_opportunity, 'CONFIRMED', NULL, now()
  );

  v_summary := henvalt.control_plane_dashboard_summary(
    'dashboard-synthetic.myshopify.com', now() - interval '1 day', now()
  );

  IF v_summary #>> '{metrics,recoveredOrders}' <> '2'
     OR v_summary #>> '{metrics,revenueRecovered}' <> '0' THEN
    RAISE EXCEPTION 'dashboard summary included unconfirmed revenue or lost confirmed attribution: %', v_summary;
  END IF;
  IF v_summary #>> '{activity,0,outcome}' <> 'recovered'
     OR v_summary #>> '{activity,0,amount}' IS NOT NULL THEN
    RAISE EXCEPTION 'confirmed attribution with nullable order value was not still shown as recovered: %', v_summary #> '{activity,0}';
  END IF;
  IF v_summary #>> '{activity,1,outcome}' <> 'pending'
     OR v_summary #>> '{activity,1,amount}' IS NOT NULL THEN
    RAISE EXCEPTION 'unconfirmed recovered opportunity was shown as recovered: %', v_summary #> '{activity,1}';
  END IF;
  IF v_summary #>> '{activity,2,outcome}' <> 'recovered'
     OR v_summary #>> '{activity,2,amount}' <> '45.67' THEN
    RAISE EXCEPTION 'confirmed attribution was not shown with attributed order value: %', v_summary #> '{activity,2}';
  END IF;
  IF v_summary #>> '{byEvent,0,recovered}' <> '2' THEN
    RAISE EXCEPTION 'by-event recovered count does not match confirmed attribution: %', v_summary #> '{byEvent,0}';
  END IF;

  INSERT INTO henvalt.revenue_ledger(
    tenant_id, order_id, opportunity_id, entry_type, amount, currency,
    billable, attribution_confidence, created_at
  ) VALUES (
    v_tenant, v_order, v_confirmed_opportunity, 'RECOVERY', 45.67, 'USD',
    true, 'CONFIRMED', now()
  );

  v_summary := henvalt.control_plane_dashboard_summary(
    'dashboard-synthetic.myshopify.com', now() - interval '1 day', now()
  );
  IF v_summary #>> '{metrics,revenueRecovered}' <> '45.67'
     OR v_summary #>> '{byEvent,0,revenueRecovered}' <> '45.67' THEN
    RAISE EXCEPTION 'dashboard revenue did not reconcile to confirmed billable ledger: %', v_summary;
  END IF;
END
$dashboard_acceptance$;



DO $token_refresh_acceptance$
DECLARE
  v_tenant uuid := gen_random_uuid();
  v_due_connection uuid := gen_random_uuid();
  v_not_due_connection uuid := gen_random_uuid();
  v_due_secret uuid := gen_random_uuid();
  v_not_due_secret uuid := gen_random_uuid();
  v_claim jsonb;
  v_lease timestamptz;
BEGIN
  INSERT INTO henvalt.tenants(id, status) VALUES (v_tenant, 'ACTIVE');
  INSERT INTO vault.decrypted_secrets(id, decrypted_secret) VALUES
    (v_due_secret, 'synthetic-refresh-token-due'),
    (v_not_due_secret, 'synthetic-refresh-token-not-due');

  INSERT INTO henvalt.shopify_connections(
    id, tenant_id, active, shop_domain, token_type, refresh_token_secret_ref,
    access_token_expires_at, refresh_token_expires_at
  ) VALUES
    (v_due_connection, v_tenant, true, 'refresh-due.myshopify.com', 'offline_expiring',
     v_due_secret::text, now() + interval '9 minutes', now() + interval '90 days'),
    (v_not_due_connection, v_tenant, true, 'refresh-not-due.myshopify.com', 'offline_expiring',
     v_not_due_secret::text, now() + interval '11 minutes', now() + interval '90 days');

  v_claim := henvalt.claim_shopify_token_refresh('refresh-due.myshopify.com', false);
  IF v_claim->>'claimed' <> 'true' THEN
    RAISE EXCEPTION 'ten-minute scheduler window failed to claim token with nine minutes remaining: %', v_claim;
  END IF;

  SELECT token_refresh_lease_until INTO v_lease
  FROM henvalt.shopify_connections WHERE id = v_due_connection;
  IF v_lease IS NULL OR v_lease <= now() THEN
    RAISE EXCEPTION 'token refresh claim did not establish a future lease';
  END IF;

  v_claim := henvalt.claim_shopify_token_refresh('refresh-not-due.myshopify.com', false);
  IF v_claim->>'claimed' <> 'false' OR v_claim->>'reason' <> 'TOKEN_STILL_VALID' THEN
    RAISE EXCEPTION 'ten-minute scheduler window claimed a token with eleven minutes remaining: %', v_claim;
  END IF;
END
$token_refresh_acceptance$;


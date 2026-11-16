-- Synthetic two-store regression test for candidate migration 009.
-- Runs after candidate migrations 001-009 in the disposable CI database.
BEGIN;

DO $$
DECLARE
  v_tenant uuid := gen_random_uuid();
  v_conn_a uuid := gen_random_uuid();
  v_conn_b uuid := gen_random_uuid();
  v_key_a text := repeat('a', 64);
  v_key_b text := repeat('b', 64);
  v_payload jsonb;
  v_result_a jsonb;
  v_result_b jsonb;
  v_inbox_a uuid;
  v_inbox_b uuid;
  v_no_consent jsonb;
  v_before_customers integer;
  v_before_sessions integer;
  v_before_aliases integer;
  v_after_customers integer;
  v_after_sessions integer;
  v_after_aliases integer;
BEGIN
  INSERT INTO henvalt.tenants(id,status) VALUES (v_tenant,'ACTIVE');
  INSERT INTO henvalt.shopify_connections(id,tenant_id,shop_domain,shopify_shop_id,active)
  VALUES
    (v_conn_a,v_tenant,'store-a.myshopify.com','1001',true),
    (v_conn_b,v_tenant,'store-b.myshopify.com','1002',true);

  INSERT INTO henvalt.pixel_keys(tenant_id,key_digest,allowed_origins,active,revoked_at,shopify_connection_id)
  VALUES
    (v_tenant,v_key_a,ARRAY['https://store-a.myshopify.com'],true,NULL,v_conn_a),
    (v_tenant,v_key_b,ARRAY['https://store-b.myshopify.com'],true,NULL,v_conn_b);

  v_payload := jsonb_build_object(
    'schema_version','1',
    'event_type','checkout_started',
    'event_id','reused-event-id',
    'client_id','reused-browser-id',
    'customer_reference','reused-shopify-customer-id',
    'checkout_reference','reused-checkout-alias',
    'analytics_consent',true,
    'marketing_consent',true,
    'occurred_at',now()
  );

  v_result_a := henvalt.ingest_pixel_event_v2(v_key_a,'https://store-a.myshopify.com',v_payload);
  v_result_b := henvalt.ingest_pixel_event_v2(v_key_b,'https://store-b.myshopify.com',v_payload);

  IF v_result_a->>'accepted' <> 'true' OR v_result_b->>'accepted' <> 'true'
     OR v_result_a->>'duplicate' <> 'false' OR v_result_b->>'duplicate' <> 'false' THEN
    RAISE EXCEPTION 'Two-store pixel inbox intake did not accept independent event IDs: %, %',v_result_a,v_result_b;
  END IF;

  v_inbox_a := (v_result_a->>'inbox_id')::uuid;
  v_inbox_b := (v_result_b->>'inbox_id')::uuid;

  PERFORM henvalt.project_shopify_pixel_identity_v2(v_inbox_a);
  PERFORM henvalt.project_shopify_pixel_identity_v2(v_inbox_b);

  SELECT count(*) INTO v_after_customers FROM henvalt.shopify_customer_identity_v2
    WHERE tenant_id=v_tenant AND external_customer_reference='reused-shopify-customer-id';
  SELECT count(*) INTO v_after_sessions FROM henvalt.shopify_session_identity_v2
    WHERE tenant_id=v_tenant AND session_reference='reused-browser-id';
  SELECT count(*) INTO v_after_aliases FROM henvalt.shopify_session_alias_identity_v2
    WHERE tenant_id=v_tenant AND alias_reference='reused-checkout-alias';

  IF v_after_customers <> 2 OR v_after_sessions <> 2 OR v_after_aliases <> 2 THEN
    RAISE EXCEPTION 'Reused external identifiers were not isolated per store: customers %, sessions %, aliases %',
      v_after_customers,v_after_sessions,v_after_aliases;
  END IF;

  -- Exact retry stays scoped to the same connection and does not duplicate.
  v_result_a := henvalt.ingest_pixel_event_v2(v_key_a,'https://store-a.myshopify.com',v_payload);
  IF v_result_a->>'duplicate' <> 'true' THEN
    RAISE EXCEPTION 'Exact retry was not idempotent: %',v_result_a;
  END IF;
  v_result_a := henvalt.project_shopify_pixel_identity_v2(v_inbox_a);
  IF v_result_a->>'duplicate' <> 'true' THEN
    RAISE EXCEPTION 'Identity projection retry was not idempotent: %',v_result_a;
  END IF;

  SELECT count(*) INTO v_before_customers FROM henvalt.shopify_customer_identity_v2 WHERE tenant_id=v_tenant;
  SELECT count(*) INTO v_before_sessions FROM henvalt.shopify_session_identity_v2 WHERE tenant_id=v_tenant;
  SELECT count(*) INTO v_before_aliases FROM henvalt.shopify_session_alias_identity_v2 WHERE tenant_id=v_tenant;

  -- Marketing consent alone must not create any customer/session/alias identity.
  v_no_consent := henvalt.ingest_pixel_event_v2(v_key_a,'https://store-a.myshopify.com',
    jsonb_build_object(
      'schema_version','1',
      'event_type','checkout_started',
      'event_id','no-analytics-consent-event',
      'client_id','must-not-persist',
      'customer_reference','must-not-persist-customer',
      'checkout_reference','must-not-persist-alias',
      'analytics_consent',false,
      'marketing_consent',true,
      'occurred_at',now()
    )
  );
  PERFORM henvalt.project_shopify_pixel_identity_v2((v_no_consent->>'inbox_id')::uuid);

  SELECT count(*) INTO v_after_customers FROM henvalt.shopify_customer_identity_v2 WHERE tenant_id=v_tenant;
  SELECT count(*) INTO v_after_sessions FROM henvalt.shopify_session_identity_v2 WHERE tenant_id=v_tenant;
  SELECT count(*) INTO v_after_aliases FROM henvalt.shopify_session_alias_identity_v2 WHERE tenant_id=v_tenant;

  IF v_before_customers <> v_after_customers
     OR v_before_sessions <> v_after_sessions
     OR v_before_aliases <> v_after_aliases THEN
    RAISE EXCEPTION 'Consent-disabled event created identity rows';
  END IF;

  IF EXISTS (
    SELECT 1 FROM henvalt.shopify_pixel_event_inbox_v2
    WHERE id=(v_no_consent->>'inbox_id')::uuid
      AND (client_reference IS NOT NULL OR customer_reference IS NOT NULL OR checkout_reference IS NOT NULL)
  ) THEN
    RAISE EXCEPTION 'Consent-disabled event persisted identity references in its inbox row';
  END IF;

  IF EXISTS (
    SELECT 1 FROM henvalt.canonical_events
    WHERE tenant_id=v_tenant
  ) THEN
    RAISE EXCEPTION 'V2 identity projection leaked into legacy canonical events';
  END IF;
END
$$;

ROLLBACK;

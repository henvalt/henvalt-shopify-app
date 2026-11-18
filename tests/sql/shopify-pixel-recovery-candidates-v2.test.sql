-- Two-store integration test for exact-store pixel cart/browse candidates.
-- Runs after candidate migrations 001-027 in disposable PostgreSQL only.
BEGIN;

DO $$
DECLARE
  v_tenant uuid := gen_random_uuid();
  v_conn_a uuid := gen_random_uuid();
  v_conn_b uuid := gen_random_uuid();
  v_domain_a text := 'pixel-a-' || left(replace(gen_random_uuid()::text,'-',''),12) || '.myshopify.com';
  v_domain_b text := 'pixel-b-' || left(replace(gen_random_uuid()::text,'-',''),12) || '.myshopify.com';
  v_origin_a text;
  v_origin_b text;
  v_key_a text;
  v_key_b text;
  v_result jsonb;
  v_inbox uuid;
  v_payload jsonb;
  v_count integer;
  v_status_a text;
  v_status_b text;
  v_app_key text := 'henvalt_pixel_test';
BEGIN
  v_origin_a := 'https://' || v_domain_a;
  v_origin_b := 'https://' || v_domain_b;
  v_key_a := encode(extensions.digest(convert_to(v_tenant::text || ':pixel-a','UTF8'),'sha256'),'hex');
  v_key_b := encode(extensions.digest(convert_to(v_tenant::text || ':pixel-b','UTF8'),'sha256'),'hex');

  INSERT INTO henvalt.tenants(id,status) VALUES (v_tenant,'ACTIVE');
  INSERT INTO henvalt.shopify_app_registry(
    app_key,shopify_client_id,webhook_secret_ref,distribution_class,lifecycle_status
  ) VALUES (v_app_key,'pixel-test-client-' || replace(v_tenant::text,'-',''),'vault://pixel-test','test','active');

  INSERT INTO henvalt.shopify_connections(id,tenant_id,shop_domain,shopify_shop_id,active,app_key)
  VALUES
    (v_conn_a,v_tenant,v_domain_a,'pixel-shop-a-' || left(v_tenant::text,8),true,v_app_key),
    (v_conn_b,v_tenant,v_domain_b,'pixel-shop-b-' || left(v_tenant::text,8),true,v_app_key);

  INSERT INTO henvalt.pixel_keys(tenant_id,key_digest,allowed_origins,active,revoked_at,shopify_connection_id)
  VALUES
    (v_tenant,v_key_a,ARRAY[v_origin_a],true,NULL,v_conn_a),
    (v_tenant,v_key_b,ARRAY[v_origin_b],true,NULL,v_conn_b);

  -- Reused browser/customer/product references across stores must stay isolated.
  FOREACH v_payload IN ARRAY ARRAY[
    jsonb_build_object('schema_version','1','event_type','product_viewed','event_id','a-view-1','client_id','shared-browser','customer_reference','shared-customer','analytics_consent',true,'marketing_consent',false,'occurred_at',now()-interval '122 minutes','product',jsonb_build_object('id','browse-product','title','Browse Product','variant_id','browse-variant','price_amount','12.00','price_currency','USD')),
    jsonb_build_object('schema_version','1','event_type','product_viewed','event_id','a-view-2','client_id','shared-browser','customer_reference','shared-customer','analytics_consent',true,'marketing_consent',false,'occurred_at',now()-interval '121 minutes','product',jsonb_build_object('id','browse-product','title','Browse Product','variant_id','browse-variant','price_amount','12.00','price_currency','USD')),
    jsonb_build_object('schema_version','1','event_type','product_added_to_cart','event_id','a-cart-add','client_id','shared-browser','customer_reference','shared-customer','analytics_consent',true,'marketing_consent',false,'occurred_at',now()-interval '120 minutes','product',jsonb_build_object('id','cart-product','title','Cart Product','variant_id','cart-variant','price_amount','19.95','price_currency','USD'),'cart_line',jsonb_build_object('quantity',1,'merchandise_id','cart-variant','product_id','cart-product','product_title','Cart Product','unit_price_amount','19.95','line_total_amount','19.95','currency','USD'))
  ] LOOP
    v_result := henvalt.ingest_pixel_event_v2(v_key_a,v_origin_a,v_payload);
    IF v_result->>'accepted' <> 'true' THEN RAISE EXCEPTION 'Store A event rejected: %',v_result; END IF;
    v_inbox := (v_result->>'inbox_id')::uuid;
    PERFORM henvalt.project_shopify_pixel_identity_v2(v_inbox);
  END LOOP;

  FOREACH v_payload IN ARRAY ARRAY[
    jsonb_build_object('schema_version','1','event_type','product_viewed','event_id','b-view-1','client_id','shared-browser','customer_reference','shared-customer','analytics_consent',true,'marketing_consent',false,'occurred_at',now()-interval '122 minutes','product',jsonb_build_object('id','browse-product','title','Browse Product','variant_id','browse-variant','price_amount','12.00','price_currency','USD')),
    jsonb_build_object('schema_version','1','event_type','product_viewed','event_id','b-view-2','client_id','shared-browser','customer_reference','shared-customer','analytics_consent',true,'marketing_consent',false,'occurred_at',now()-interval '121 minutes','product',jsonb_build_object('id','browse-product','title','Browse Product','variant_id','browse-variant','price_amount','12.00','price_currency','USD')),
    jsonb_build_object('schema_version','1','event_type','product_added_to_cart','event_id','b-cart-add','client_id','shared-browser','customer_reference','shared-customer','analytics_consent',true,'marketing_consent',false,'occurred_at',now()-interval '120 minutes','product',jsonb_build_object('id','cart-product','title','Cart Product','variant_id','cart-variant','price_amount','19.95','price_currency','USD'),'cart_line',jsonb_build_object('quantity',1,'merchandise_id','cart-variant','product_id','cart-product','product_title','Cart Product','unit_price_amount','19.95','line_total_amount','19.95','currency','USD'))
  ] LOOP
    v_result := henvalt.ingest_pixel_event_v2(v_key_b,v_origin_b,v_payload);
    IF v_result->>'accepted' <> 'true' THEN RAISE EXCEPTION 'Store B event rejected: %',v_result; END IF;
    v_inbox := (v_result->>'inbox_id')::uuid;
    PERFORM henvalt.project_shopify_pixel_identity_v2(v_inbox);
  END LOOP;

  v_result := henvalt.refresh_shopify_pixel_recovery_candidates_v2(
    interval '30 minutes', interval '24 hours', 100
  );
  IF v_result->>'accepted' <> 'true' THEN RAISE EXCEPTION 'Candidate refresh rejected: %',v_result; END IF;

  SELECT count(*) INTO v_count
  FROM henvalt.shopify_pixel_recovery_candidate_v2
  WHERE tenant_id=v_tenant AND status='READY_FOR_REVIEW';
  IF v_count <> 4 THEN
    RAISE EXCEPTION 'Expected 4 exact-store cart/browse candidates, found %',v_count;
  END IF;

  IF (SELECT count(DISTINCT shopify_connection_id)
      FROM henvalt.shopify_pixel_recovery_candidate_v2
      WHERE tenant_id=v_tenant) <> 2 THEN
    RAISE EXCEPTION 'Candidates did not remain separated by store connection';
  END IF;

  -- A later removal in Store A suppresses only Store A's cart candidate.
  v_payload := jsonb_build_object(
    'schema_version','1','event_type','product_removed_from_cart',
    'event_id','a-cart-remove','client_id','shared-browser',
    'customer_reference','shared-customer','analytics_consent',true,
    'marketing_consent',false,'occurred_at',now()-interval '60 minutes',
    'product',jsonb_build_object('id','cart-product','title','Cart Product','variant_id','cart-variant'),
    'cart_line',jsonb_build_object('quantity',0,'merchandise_id','cart-variant','product_id','cart-product','product_title','Cart Product')
  );
  v_result := henvalt.ingest_pixel_event_v2(v_key_a,v_origin_a,v_payload);
  v_inbox := (v_result->>'inbox_id')::uuid;
  PERFORM henvalt.project_shopify_pixel_identity_v2(v_inbox);
  PERFORM henvalt.refresh_shopify_pixel_recovery_candidates_v2(
    interval '30 minutes', interval '24 hours', 100
  );

  SELECT status INTO v_status_a
  FROM henvalt.shopify_pixel_recovery_candidate_v2
  WHERE tenant_id=v_tenant AND shopify_connection_id=v_conn_a
    AND candidate_type='ABANDONED_CART';
  SELECT status INTO v_status_b
  FROM henvalt.shopify_pixel_recovery_candidate_v2
  WHERE tenant_id=v_tenant AND shopify_connection_id=v_conn_b
    AND candidate_type='ABANDONED_CART';

  IF v_status_a IS DISTINCT FROM 'SUPPRESSED'
     OR v_status_b IS DISTINCT FROM 'READY_FOR_REVIEW' THEN
    RAISE EXCEPTION 'Cross-store suppression failure: Store A %, Store B %',v_status_a,v_status_b;
  END IF;

  v_result := henvalt.promote_shopify_pixel_recovery_candidates_v2(100);
  IF v_result->>'accepted' <> 'true' OR (v_result->>'opportunities_created')::integer <> 3 THEN
    RAISE EXCEPTION 'Expected three cart/browse opportunities after Store A cart suppression: %',v_result;
  END IF;

  SELECT count(*) INTO v_count
  FROM henvalt.shopify_recovery_opportunity_v2
  WHERE tenant_id=v_tenant
    AND opportunity_type IN ('ABANDONED_CART','BROWSE_ABANDONMENT');
  IF v_count <> 3 THEN
    RAISE EXCEPTION 'Expected three generalized cart/browse opportunities, found %',v_count;
  END IF;

  IF EXISTS (
    SELECT 1 FROM henvalt.shopify_recovery_intervention_v2 i
    JOIN henvalt.shopify_recovery_opportunity_v2 o ON o.id=i.opportunity_id
    WHERE o.tenant_id=v_tenant
      AND o.opportunity_type IN ('ABANDONED_CART','BROWSE_ABANDONMENT')
  ) THEN
    RAISE EXCEPTION 'Generalized candidate promotion unexpectedly created delivery interventions';
  END IF;
END
$$;

ROLLBACK;

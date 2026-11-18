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
  v_customer_a uuid;
  v_customer_b uuid;
  v_lookup_id uuid := gen_random_uuid();
  v_evidence_result jsonb;
  v_eligibility_result jsonb;
  v_pixel_opportunity_id uuid;
  v_app_key text := 'henvalt_pixel_test';
  v_provider_key text := repeat('p',32);
  v_sender_profile_id uuid;
  v_permit_result jsonb;
  v_consume_result jsonb;
  v_permit_token text;
  v_pixel_attempt_id uuid;
  v_cost_status text;
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

  -- Trusted Admin API evidence is recorded separately per exact installation.
  SELECT customer_identity_id INTO v_customer_a
  FROM henvalt.shopify_pixel_recovery_candidate_v2
  WHERE tenant_id=v_tenant AND shopify_connection_id=v_conn_a
    AND customer_identity_id IS NOT NULL
  LIMIT 1;
  SELECT customer_identity_id INTO v_customer_b
  FROM henvalt.shopify_pixel_recovery_candidate_v2
  WHERE tenant_id=v_tenant AND shopify_connection_id=v_conn_b
    AND customer_identity_id IS NOT NULL
  LIMIT 1;

  IF v_customer_a IS NULL OR v_customer_b IS NULL OR v_customer_a=v_customer_b THEN
    RAISE EXCEPTION 'Expected separate exact-store customer identities';
  END IF;

  v_evidence_result := henvalt.record_shopify_customer_contact_evidence_v2(
    v_conn_a,v_customer_a,true,'GB',pg_catalog.now(),v_lookup_id
  );
  IF v_evidence_result->>'accepted'<>'true'
     OR v_evidence_result->>'send_authorized'<>'false' THEN
    RAISE EXCEPTION 'Store A contact evidence was not safely recorded: %',v_evidence_result;
  END IF;

  v_evidence_result := henvalt.record_shopify_customer_contact_evidence_v2(
    v_conn_b,v_customer_a,true,'US',pg_catalog.now(),gen_random_uuid()
  );
  IF v_evidence_result->>'accepted'<>'false'
     OR v_evidence_result->>'code'<>'CUSTOMER_IDENTITY_SCOPE_MISMATCH' THEN
    RAISE EXCEPTION 'Store A customer identity was accepted under Store B: %',v_evidence_result;
  END IF;

  v_evidence_result := henvalt.record_shopify_customer_contact_evidence_v2(
    v_conn_b,v_customer_b,false,NULL,pg_catalog.now(),gen_random_uuid()
  );
  IF v_evidence_result->>'accepted'<>'true'
     OR v_evidence_result->>'contact_value_stored'<>'false' THEN
    RAISE EXCEPTION 'Store B unavailable-contact evidence was not safely recorded: %',v_evidence_result;
  END IF;

  IF (SELECT count(*) FROM henvalt.shopify_customer_contact_evidence_current_v2
      WHERE tenant_id=v_tenant)<>2 THEN
    RAISE EXCEPTION 'Contact evidence was not isolated by exact store';
  END IF;

  v_evidence_result := henvalt.record_shopify_customer_contact_evidence_v2(
    v_conn_a,v_customer_a,true,'US',pg_catalog.now()-interval '1 minute',gen_random_uuid()
  );
  IF v_evidence_result->>'accepted'<>'true'
     OR v_evidence_result->>'current_updated'<>'false' THEN
    RAISE EXCEPTION 'Older contact evidence unexpectedly replaced current evidence: %',v_evidence_result;
  END IF;
  IF (SELECT country_code FROM henvalt.shopify_customer_contact_evidence_current_v2
      WHERE shopify_connection_id=v_conn_a AND customer_identity_id=v_customer_a)<>'GB' THEN
    RAISE EXCEPTION 'Older contact evidence replaced the current country';
  END IF;

  v_evidence_result := henvalt.record_shopify_customer_contact_evidence_v2(
    v_conn_a,v_customer_a,true,'US',pg_catalog.now(),v_lookup_id
  );
  IF v_evidence_result->>'accepted'<>'false'
     OR v_evidence_result->>'code'<>'LOOKUP_ID_REPLAY_MISMATCH' THEN
    RAISE EXCEPTION 'Lookup ID replay with altered facts was not rejected: %',v_evidence_result;
  END IF;

  -- New V3 resolver stores only Shopify's region code alongside country.
  v_evidence_result := henvalt.record_shopify_customer_contact_evidence_v3(
    v_conn_a,v_customer_a,true,'US','CA',pg_catalog.clock_timestamp(),gen_random_uuid()
  );
  IF v_evidence_result->>'accepted'<>'true'
     OR v_evidence_result->>'send_authorized'<>'false' THEN
    RAISE EXCEPTION 'Subnational contact evidence was not safely recorded: %',v_evidence_result;
  END IF;
  IF (SELECT country_code FROM henvalt.shopify_customer_contact_evidence_current_v2
      WHERE shopify_connection_id=v_conn_a AND customer_identity_id=v_customer_a)<>'US'
     OR (SELECT region_code FROM henvalt.shopify_customer_contact_evidence_current_v2
      WHERE shopify_connection_id=v_conn_a AND customer_identity_id=v_customer_a)<>'CA' THEN
    RAISE EXCEPTION 'Current country/region evidence was not retained together';
  END IF;
  v_evidence_result := henvalt.record_shopify_customer_contact_evidence_v3(
    v_conn_a,v_customer_a,true,'US','NY',pg_catalog.now(),v_lookup_id
  );
  IF v_evidence_result->>'accepted'<>'false'
     OR v_evidence_result->>'code'<>'LOOKUP_ID_REPLAY_MISMATCH' THEN
    RAISE EXCEPTION 'Region change under reused lookup ID was not rejected: %',v_evidence_result;
  END IF;

  -- Even with fresh contact/location evidence, cart/browse stays blocked until
  -- an exact country/region policy row has a documented legal review.
  UPDATE henvalt.shopify_connections
     SET token_type='offline_expiring',
         scopes=ARRAY['read_customers'],
         access_token_expires_at=pg_catalog.now()+interval '1 hour',
         reauth_required_at=NULL
   WHERE id=v_conn_a AND tenant_id=v_tenant;
  IF EXISTS (
    SELECT 1 FROM henvalt.shopify_pixel_delivery_jurisdiction_policy_v2
    WHERE country_code='US' AND region_code='CA'
  ) THEN
    RAISE EXCEPTION 'Test requires an empty jurisdiction policy registry';
  END IF;
  SELECT id INTO v_pixel_opportunity_id
  FROM henvalt.shopify_recovery_opportunity_v2
  WHERE tenant_id=v_tenant AND shopify_connection_id=v_conn_a
    AND opportunity_type IN ('ABANDONED_CART','BROWSE_ABANDONMENT')
  ORDER BY created_at LIMIT 1;
  PERFORM pg_catalog.set_config('request.jwt.claim.role','service_role',true);
  v_eligibility_result := henvalt.assess_shopify_pixel_delivery_eligibility_v2(v_pixel_opportunity_id);
  IF v_eligibility_result->>'eligible'<>'false'
     OR v_eligibility_result->>'code'<>'JURISDICTION_POLICY_NOT_APPROVED'
     OR v_eligibility_result->>'delivery_authorized'<>'false' THEN
    RAISE EXCEPTION 'Cart/browse did not fail closed without approved jurisdiction policy: %',v_eligibility_result;
  END IF;

  -- Fresh Admin API marketing-consent evidence is append-only and exact-store scoped.
  v_lookup_id := gen_random_uuid();
  v_evidence_result := henvalt.record_shopify_customer_marketing_consent_lookup_v2(
    v_conn_a,v_customer_a,'SUBSCRIBED',pg_catalog.now()-interval '10 minutes',
    pg_catalog.clock_timestamp(),v_lookup_id
  );
  IF v_evidence_result->>'accepted'<>'true'
     OR v_evidence_result->>'delivery_authorized'<>'false' THEN
    RAISE EXCEPTION 'Fresh Admin API consent evidence was not safely recorded: %',v_evidence_result;
  END IF;
  IF (SELECT marketing_state FROM henvalt.shopify_customer_marketing_consent_lookup_current_v2
      WHERE shopify_connection_id=v_conn_a AND customer_identity_id=v_customer_a)<>'SUBSCRIBED' THEN
    RAISE EXCEPTION 'Admin API consent state was not projected to the current pointer';
  END IF;

  v_evidence_result := henvalt.record_shopify_customer_marketing_consent_lookup_v2(
    v_conn_b,v_customer_a,'SUBSCRIBED',pg_catalog.now(),pg_catalog.clock_timestamp(),gen_random_uuid()
  );
  IF v_evidence_result->>'accepted'<>'false'
     OR v_evidence_result->>'code'<>'CUSTOMER_IDENTITY_SCOPE_MISMATCH' THEN
    RAISE EXCEPTION 'Cross-store consent evidence was accepted: %',v_evidence_result;
  END IF;

  v_evidence_result := henvalt.record_shopify_customer_marketing_consent_lookup_v2(
    v_conn_a,v_customer_a,'UNSUBSCRIBED',pg_catalog.now(),pg_catalog.clock_timestamp(),v_lookup_id
  );
  IF v_evidence_result->>'accepted'<>'false'
     OR v_evidence_result->>'code'<>'LOOKUP_ID_REPLAY_MISMATCH' THEN
    RAISE EXCEPTION 'Consent lookup replay with altered state was not rejected: %',v_evidence_result;
  END IF;

  -- Disposable-only approved policy and provider/billing fixtures enable a real
  -- pixel permit issue/consume test. This legal-review reference is synthetic and
  -- the surrounding transaction is rolled back below; it is not a live approval.
  INSERT INTO henvalt.shopify_pixel_delivery_jurisdiction_policy_v2(
    country_code,region_code,policy_version,policy_status,legal_review_reference,
    require_region,max_consent_evidence_age,max_contact_evidence_age,approved_at
  ) VALUES('US','CA','test-policy-v1','APPROVED','TEST-ONLY-LEGAL-REVIEW-REFERENCE',
    true,interval '30 days',interval '15 minutes',pg_catalog.now());

  INSERT INTO henvalt.billing_accounts(
    tenant_id,henvalt_percentage,usage_cap_amount,currency,status,test_mode,monthly_email_limit
  ) VALUES(v_tenant,5,1.00,'USD','ACTIVE',false,10);

  INSERT INTO henvalt.shopify_mailer_provider_registry_v2(
    tenant_id,provider_account_key,mailersend_domain_id,webhook_secret_ref,
    recipient_fingerprint_secret_ref,status,email_unit_cost_amount,email_unit_cost_currency
  ) VALUES(v_tenant,v_provider_key,'pixel-test-domain','vault://pixel-test-webhook',
    'vault://pixel-test-fingerprint','ACTIVE',0.01,'USD');

  INSERT INTO henvalt.shopify_sender_profiles_v2(
    tenant_id,shopify_connection_id,provider_account_key,from_email,from_name,status,verified_at
  ) VALUES(v_tenant,v_conn_a,v_provider_key,'recovery@example.test','HENVALT Test',
    'ACTIVE',pg_catalog.now())
  RETURNING id INTO v_sender_profile_id;

  -- Refresh the Admin API consent observation immediately before authorization.
  v_evidence_result:=henvalt.record_shopify_customer_marketing_consent_lookup_v2(
    v_conn_a,v_customer_a,'SUBSCRIBED',pg_catalog.now()-interval '1 minute',
    pg_catalog.clock_timestamp(),gen_random_uuid()
  );
  IF v_evidence_result->>'accepted'<>'true' THEN
    RAISE EXCEPTION 'Fresh consent lookup could not be refreshed for permit test: %',v_evidence_result;
  END IF;

  v_eligibility_result:=henvalt.assess_shopify_pixel_delivery_eligibility_v2(v_pixel_opportunity_id);
  IF v_eligibility_result->>'eligible'<>'true'
     OR v_eligibility_result->>'delivery_authorized'<>'false' THEN
    RAISE EXCEPTION 'Pixel opportunity did not reach the authorization-review state: %',v_eligibility_result;
  END IF;

  v_permit_result:=henvalt.issue_shopify_pixel_delivery_permit_v2(
    v_pixel_opportunity_id,v_provider_key,v_sender_profile_id,repeat('a',64)
  );
  IF v_permit_result->>'authorized'<>'true'
     OR v_permit_result->>'delivery_authorized'<>'false'
     OR v_permit_result->>'provider_cost_reserved'<>'false' THEN
    RAISE EXCEPTION 'Pixel permit was not safely issued: %',v_permit_result;
  END IF;
  v_permit_token:=v_permit_result->>'permit_token';
  IF v_permit_token IS NULL OR length(v_permit_token)<>64 OR EXISTS(
    SELECT 1 FROM henvalt.shopify_pixel_delivery_permits_v2
    WHERE permit_token_sha256=v_permit_token
  ) THEN
    RAISE EXCEPTION 'Permit token was not returned as a one-time secret with hash-only storage';
  END IF;
  IF NOT EXISTS(
    SELECT 1 FROM henvalt.shopify_pixel_delivery_permits_v2
    WHERE opportunity_id=v_pixel_opportunity_id
      AND permit_token_sha256=encode(extensions.digest(convert_to(v_permit_token,'UTF8'),'sha256'),'hex')
  ) THEN
    RAISE EXCEPTION 'Permit token hash was not stored for verification';
  END IF;

  PERFORM pg_catalog.set_config('request.jwt.claim.role','service_role',true);

  -- Duplicate issuance is serialized on the opportunity row and must not mint
  -- a second active permit for the same recovery opportunity.
  v_permit_result:=henvalt.issue_shopify_pixel_delivery_permit_v2(
    v_pixel_opportunity_id,v_provider_key,v_sender_profile_id,repeat('a',64)
  );
  IF v_permit_result->>'authorized'<>'false'
     OR v_permit_result->>'code'<>'PIXEL_DELIVERY_ALREADY_CLAIMED' THEN
    RAISE EXCEPTION 'Duplicate active permit issuance was not rejected: %',v_permit_result;
  END IF;

  -- Expiry is enforced at consume time, independently of issuance-time checks.
  UPDATE henvalt.shopify_pixel_delivery_permits_v2
     SET expires_at=pg_catalog.now()-interval '1 second'
   WHERE opportunity_id=v_pixel_opportunity_id AND consumed_at IS NULL;
  v_consume_result:=henvalt.consume_shopify_pixel_delivery_permit_v2(v_permit_token);
  IF v_consume_result->>'consumed'<>'false'
     OR v_consume_result->>'code'<>'PERMIT_EXPIRED' THEN
    RAISE EXCEPTION 'Expired pixel permit was not rejected: %',v_consume_result;
  END IF;
  UPDATE henvalt.shopify_pixel_delivery_permits_v2
     SET expires_at=pg_catalog.now()+interval '2 minutes'
   WHERE opportunity_id=v_pixel_opportunity_id AND consumed_at IS NULL;

  -- Adverse race: consent is revoked after permit issuance but before consume.
  -- The old permit must become unusable without creating an attempt or reserving cost.
  v_evidence_result:=henvalt.record_shopify_customer_marketing_consent_lookup_v2(
    v_conn_a,v_customer_a,'UNSUBSCRIBED',pg_catalog.now()-interval '30 seconds',
    pg_catalog.clock_timestamp(),gen_random_uuid()
  );
  IF v_evidence_result->>'accepted'<>'true' THEN
    RAISE EXCEPTION 'Consent revocation evidence could not be recorded: %',v_evidence_result;
  END IF;
  v_consume_result:=henvalt.consume_shopify_pixel_delivery_permit_v2(v_permit_token);
  IF v_consume_result->>'consumed'<>'false'
     OR v_consume_result->>'code'<>'FRESH_ADMIN_API_SUBSCRIBED_CONSENT_REQUIRED' THEN
    RAISE EXCEPTION 'Permit survived consent revocation before consume: %',v_consume_result;
  END IF;
  IF EXISTS(SELECT 1 FROM henvalt.shopify_pixel_send_attempts_v2 WHERE opportunity_id=v_pixel_opportunity_id)
     OR EXISTS(SELECT 1 FROM henvalt.shopify_pixel_delivery_cost_reservations_v2 WHERE opportunity_id=v_pixel_opportunity_id) THEN
    RAISE EXCEPTION 'Revoked-consent permit created an attempt or cost reservation';
  END IF;

  -- A fresh positive Admin API lookup is required before a new permit may be issued.
  v_evidence_result:=henvalt.record_shopify_customer_marketing_consent_lookup_v2(
    v_conn_a,v_customer_a,'SUBSCRIBED',pg_catalog.now()-interval '20 seconds',
    pg_catalog.clock_timestamp(),gen_random_uuid()
  );
  IF v_evidence_result->>'accepted'<>'true' THEN
    RAISE EXCEPTION 'Fresh subscribed consent could not be restored for isolated positive-path test: %',v_evidence_result;
  END IF;
  v_permit_result:=henvalt.issue_shopify_pixel_delivery_permit_v2(
    v_pixel_opportunity_id,v_provider_key,v_sender_profile_id,repeat('a',64)
  );
  IF v_permit_result->>'authorized'<>'true' THEN
    RAISE EXCEPTION 'New permit was not issued after fresh subscribed evidence: %',v_permit_result;
  END IF;
  v_permit_token:=v_permit_result->>'permit_token';

  v_consume_result:=henvalt.consume_shopify_pixel_delivery_permit_v2(v_permit_token);
  IF v_consume_result->>'consumed'<>'true'
     OR v_consume_result->>'recipient_email_returned'<>'false'
     OR v_consume_result->>'provider_submission_performed'<>'false'
     OR v_consume_result->>'provider_cost_reserved'<>'true' THEN
    RAISE EXCEPTION 'Pixel permit consumption did not create a metadata-only reserved attempt: %',v_consume_result;
  END IF;
  v_pixel_attempt_id:=(v_consume_result->>'pixel_send_attempt_id')::uuid;

  SELECT status INTO v_cost_status FROM henvalt.shopify_pixel_delivery_cost_reservations_v2
  WHERE pixel_send_attempt_id=v_pixel_attempt_id;
  IF v_cost_status IS DISTINCT FROM 'RESERVED' THEN
    RAISE EXCEPTION 'Pixel permit consumption did not reserve provider cost';
  END IF;

  -- Second adverse race: consent is revoked after consume but before the
  -- provider-submission gate. The attempt remains unsent and cannot pass final auth.
  v_evidence_result:=henvalt.record_shopify_customer_marketing_consent_lookup_v2(
    v_conn_a,v_customer_a,'UNSUBSCRIBED',pg_catalog.now()-interval '10 seconds',
    pg_catalog.clock_timestamp(),gen_random_uuid()
  );
  IF v_evidence_result->>'accepted'<>'true' THEN
    RAISE EXCEPTION 'Late consent revocation evidence could not be recorded: %',v_evidence_result;
  END IF;
  v_evidence_result:=henvalt.authorize_shopify_pixel_provider_submission_v2(
    v_pixel_attempt_id,repeat('a',64)
  );
  IF v_evidence_result->>'authorized'<>'false'
     OR v_evidence_result->>'code'<>'FRESH_ADMIN_API_SUBSCRIBED_CONSENT_REQUIRED'
     OR v_evidence_result ? 'provider_submission_performed' THEN
    RAISE EXCEPTION 'Final provider gate failed to block late consent revocation: %',v_evidence_result;
  END IF;

  v_consume_result:=henvalt.consume_shopify_pixel_delivery_permit_v2(v_permit_token);
  IF v_consume_result->>'consumed'<>'false'
     OR v_consume_result->>'code'<>'PERMIT_ALREADY_USED' THEN
    RAISE EXCEPTION 'Pixel permit replay was not rejected: %',v_consume_result;
  END IF;

  v_evidence_result:=henvalt.record_shopify_pixel_send_attempt_result_v2(
    v_pixel_attempt_id,'FAILED',NULL
  );
  IF v_evidence_result->>'recorded'<>'true'
     OR v_evidence_result->>'provider_cost_state'<>'RELEASED' THEN
    RAISE EXCEPTION 'Test pixel attempt did not release its reservation on pre-provider failure: %',v_evidence_result;
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

-- Exact-store recovery opportunity promotion regression.
-- Runs after checkout eligibility test in the disposable PostgreSQL database.
\set ON_ERROR_STOP on
DO $opportunity_v2$
DECLARE
  v_tenant uuid := '00000000-0000-4000-8000-000000000001';
  v_store_a uuid;
  v_store_b uuid;
  v_receipt_a uuid;
  v_receipt_b uuid;
  v_customer_a uuid;
  v_customer_b uuid;
  v_checkout_a uuid;
  v_checkout_b uuid;
  v_result jsonb;
  v_a integer;
  v_b integer;
BEGIN
  SELECT id INTO v_store_a FROM henvalt.shopify_connections WHERE shop_domain='store-a.myshopify.com';
  SELECT id INTO v_store_b FROM henvalt.shopify_connections WHERE shop_domain='store-b.myshopify.com';
  SELECT id INTO v_receipt_a FROM henvalt.shopify_webhook_deliveries WHERE shopify_delivery_id='eligibility-checkout-a';
  SELECT id INTO v_receipt_b FROM henvalt.shopify_webhook_deliveries WHERE shopify_delivery_id='eligibility-checkout-b';
  SELECT id INTO v_customer_a FROM henvalt.shopify_customer_identity_v2
    WHERE shopify_connection_id=v_store_a AND external_customer_reference='12345';
  SELECT id INTO v_customer_b FROM henvalt.shopify_customer_identity_v2
    WHERE shopify_connection_id=v_store_b AND external_customer_reference='12345';

  IF v_store_a IS NULL OR v_store_b IS NULL OR v_receipt_a IS NULL OR v_receipt_b IS NULL
     OR v_customer_a IS NULL OR v_customer_b IS NULL THEN
    RAISE EXCEPTION 'Opportunity V2 test prerequisites missing';
  END IF;

  INSERT INTO henvalt.shopify_checkout_identity_v2 (
    tenant_id, shopify_connection_id, shopify_checkout_id, shopify_checkout_token,
    total_value, currency, customer_identity_id, source_delivery_id, checkout_status,
    created_at, updated_at
  ) VALUES
    (v_tenant,v_store_a,NULL,'opportunity-shared-token',125.50,'USD',v_customer_a,v_receipt_a,'OPEN',now()-interval '2 hours',now()-interval '2 hours'),
    (v_tenant,v_store_b,NULL,'opportunity-shared-token',75.00,'GBP',v_customer_b,v_receipt_b,'OPEN',now()-interval '2 hours',now()-interval '2 hours')
  ON CONFLICT (shopify_connection_id,shopify_checkout_token) DO NOTHING;

  SELECT id INTO v_checkout_a FROM henvalt.shopify_checkout_identity_v2
   WHERE shopify_connection_id=v_store_a AND shopify_checkout_token='opportunity-shared-token';
  SELECT id INTO v_checkout_b FROM henvalt.shopify_checkout_identity_v2
   WHERE shopify_connection_id=v_store_b AND shopify_checkout_token='opportunity-shared-token';

  INSERT INTO henvalt.shopify_checkout_recovery_candidate_v2 (
    tenant_id,shopify_connection_id,checkout_identity_id,checkout_token,source_delivery_id,
    last_activity_at,eligible_after,state
  ) VALUES
    (v_tenant,v_store_a,v_checkout_a,'opportunity-shared-token',v_receipt_a,now()-interval '2 hours',now()-interval '1 minute','READY_FOR_CONTACT_RESOLUTION'),
    (v_tenant,v_store_b,v_checkout_b,'opportunity-shared-token',v_receipt_b,now()-interval '2 hours',now()-interval '1 minute','READY_FOR_CONTACT_RESOLUTION')
  ON CONFLICT (shopify_connection_id,checkout_token) DO NOTHING;

  v_result := henvalt.promote_shopify_checkout_recovery_candidates_v2(100);
  IF v_result->>'accepted'<>'true' OR v_result->>'delivery_authorized'<>'false' THEN
    RAISE EXCEPTION 'Opportunity promotion rejected or authorized delivery: %',v_result;
  END IF;

  SELECT count(*) INTO v_a FROM henvalt.shopify_recovery_opportunity_v2
   WHERE shopify_connection_id=v_store_a AND candidate_id IN (
     SELECT id FROM henvalt.shopify_checkout_recovery_candidate_v2 WHERE checkout_token='opportunity-shared-token'
   );
  SELECT count(*) INTO v_b FROM henvalt.shopify_recovery_opportunity_v2
   WHERE shopify_connection_id=v_store_b AND candidate_id IN (
     SELECT id FROM henvalt.shopify_checkout_recovery_candidate_v2 WHERE checkout_token='opportunity-shared-token'
   );
  IF v_a<>1 OR v_b<>1 THEN
    RAISE EXCEPTION 'Same checkout token did not create one independent opportunity per store: A %, B %',v_a,v_b;
  END IF;

  IF EXISTS (
    SELECT 1 FROM henvalt.shopify_recovery_opportunity_v2
    WHERE shopify_connection_id=v_store_a AND status<>'CONTACT_RESOLUTION_PENDING'
  ) OR EXISTS (
    SELECT 1 FROM henvalt.shopify_recovery_opportunity_v2
    WHERE shopify_connection_id=v_store_b AND status<>'CONTACT_RESOLUTION_PENDING'
  ) THEN
    RAISE EXCEPTION 'Expected exact-store customer opportunities to await contact resolution';
  END IF;

  -- Repeated promotion must not create duplicate opportunities.
  v_result := henvalt.promote_shopify_checkout_recovery_candidates_v2(100);
  IF v_result->>'opportunities_created'<>'0' THEN
    RAISE EXCEPTION 'Repeated promotion was not idempotent: %',v_result;
  END IF;
END;
$opportunity_v2$;

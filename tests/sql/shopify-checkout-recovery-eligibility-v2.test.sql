-- Exact-store checkout eligibility and order suppression regression.
-- Runs after the checkout and order projection integration tests.
\set ON_ERROR_STOP on
DO $eligibility_v2$
DECLARE
  v_tenant uuid := '00000000-0000-4000-8000-000000000001';
  v_store_a uuid;
  v_store_b uuid;
  v_token_a text := repeat('b',64);
  v_token_b text := repeat('c',64);
  v_checkout_a text := '{"shop_id":"1001","id":777001,"token":"eligibility-shared-token","customer":{"id":12345},"total_price":"125.50","currency":"USD","completed_at":null}';
  v_checkout_b text := '{"shop_id":"2002","id":777001,"token":"eligibility-shared-token","customer":{"id":12345},"total_price":"75.00","currency":"GBP","completed_at":null}';
  v_order_a text := '{"shop_id":"1001","id":888001,"checkout_token":"eligibility-shared-token","customer":{"id":12345},"total_price":"125.50","currency":"USD","financial_status":"paid","created_at":"2026-11-17T00:00:00Z"}';
  v_hmac text;
  v_receipt record;
  v_result jsonb;
  v_count_a integer;
  v_count_b integer;
BEGIN
  SELECT id INTO v_store_a FROM henvalt.shopify_connections WHERE shop_domain='store-a.myshopify.com';
  SELECT id INTO v_store_b FROM henvalt.shopify_connections WHERE shop_domain='store-b.myshopify.com';
  IF v_store_a IS NULL OR v_store_b IS NULL THEN
    RAISE EXCEPTION 'Eligibility V2 test requires both synthetic stores';
  END IF;
  UPDATE henvalt.shopify_connections SET active=true WHERE id IN (v_store_a,v_store_b);

  v_hmac := encode(extensions.hmac(convert_to(v_checkout_a,'UTF8'),convert_to('synthetic-test-secret-never-used-in-production','UTF8'),'sha256'),'base64');
  SELECT * INTO v_receipt FROM henvalt.accept_shopify_webhook_v2(
    v_token_a,v_hmac,encode(convert_to(v_checkout_a,'UTF8'),'base64'),
    'store-a.myshopify.com','checkouts/create','eligibility-checkout-a','eligibility-event-a'
  );
  IF v_receipt.accepted IS DISTINCT FROM true THEN RAISE EXCEPTION 'Store A checkout receipt rejected'; END IF;
  v_result := henvalt.project_verified_shopify_checkout_v2(v_token_a,'eligibility-checkout-a',encode(convert_to(v_checkout_a,'UTF8'),'base64'));
  IF v_result->>'status'<>'OPEN' THEN RAISE EXCEPTION 'Store A checkout projection failed: %',v_result; END IF;

  v_hmac := encode(extensions.hmac(convert_to(v_checkout_b,'UTF8'),convert_to('synthetic-test-secret-never-used-in-production','UTF8'),'sha256'),'base64');
  SELECT * INTO v_receipt FROM henvalt.accept_shopify_webhook_v2(
    v_token_b,v_hmac,encode(convert_to(v_checkout_b,'UTF8'),'base64'),
    'store-b.myshopify.com','checkouts/create','eligibility-checkout-b','eligibility-event-b'
  );
  IF v_receipt.accepted IS DISTINCT FROM true THEN RAISE EXCEPTION 'Store B checkout receipt rejected'; END IF;
  v_result := henvalt.project_verified_shopify_checkout_v2(v_token_b,'eligibility-checkout-b',encode(convert_to(v_checkout_b,'UTF8'),'base64'));
  IF v_result->>'status'<>'OPEN' THEN RAISE EXCEPTION 'Store B checkout projection failed: %',v_result; END IF;

  -- Simulate inactivity without relying on wall-clock sleeps.
  UPDATE henvalt.shopify_checkout_identity_v2
     SET updated_at=now()-interval '2 hours'
   WHERE shopify_checkout_token='eligibility-shared-token'
     AND shopify_connection_id IN (v_store_a,v_store_b);

  -- A verified order in Store A must complete only Store A's checkout.
  v_hmac := encode(extensions.hmac(convert_to(v_order_a,'UTF8'),convert_to('synthetic-test-secret-never-used-in-production','UTF8'),'sha256'),'base64');
  SELECT * INTO v_receipt FROM henvalt.accept_shopify_webhook_v2(
    v_token_a,v_hmac,encode(convert_to(v_order_a,'UTF8'),'base64'),
    'store-a.myshopify.com','orders/create','eligibility-order-a','eligibility-order-event-a'
  );
  IF v_receipt.accepted IS DISTINCT FROM true THEN RAISE EXCEPTION 'Store A order receipt rejected'; END IF;
  v_result := henvalt.project_verified_shopify_order_v2(v_token_a,'eligibility-order-a',encode(convert_to(v_order_a,'UTF8'),'base64'));
  IF v_result->>'checkout_match_status'<>'MATCHED' THEN RAISE EXCEPTION 'Store A order did not suppress its checkout: %',v_result; END IF;

  v_result := henvalt.refresh_shopify_checkout_recovery_candidates_v2(interval '1 hour',100);
  IF v_result->>'accepted'<>'true' OR v_result->>'delivery_authorized'<>'false' THEN
    RAISE EXCEPTION 'Eligibility refresh failed or authorized delivery: %',v_result;
  END IF;

  SELECT count(*) INTO v_count_a FROM henvalt.shopify_checkout_recovery_candidate_v2
   WHERE shopify_connection_id=v_store_a AND checkout_token='eligibility-shared-token';
  SELECT count(*) INTO v_count_b FROM henvalt.shopify_checkout_recovery_candidate_v2
   WHERE shopify_connection_id=v_store_b AND checkout_token='eligibility-shared-token'
     AND state='READY_FOR_CONTACT_RESOLUTION'
     AND eligible_after <= now();
  IF v_count_a<>0 OR v_count_b<>1 THEN
    RAISE EXCEPTION 'Cross-store conversion suppression failed: Store A candidates %, Store B eligible %',v_count_a,v_count_b;
  END IF;

  -- Once a checkout is observed closed, a later contradictory/open projection
  -- must not resurrect its terminal recovery candidate.
  UPDATE henvalt.shopify_checkout_identity_v2
     SET checkout_status='COMPLETED'
   WHERE shopify_connection_id=v_store_b
     AND shopify_checkout_token='eligibility-shared-token';
  PERFORM henvalt.refresh_shopify_checkout_recovery_candidates_v2(interval '1 hour',100);
  IF NOT EXISTS (
    SELECT 1 FROM henvalt.shopify_checkout_recovery_candidate_v2
    WHERE shopify_connection_id=v_store_b
      AND checkout_token='eligibility-shared-token'
      AND state='CHECKOUT_CLOSED'
  ) THEN
    RAISE EXCEPTION 'Closed checkout did not move its candidate into the terminal closed state';
  END IF;

  -- Simulate a later open projection to exercise the refresh upsert itself.
  -- The production checkout projection is monotonic for completion and cannot
  -- reopen a completed checkout, but the candidate must remain fail-closed.
  UPDATE henvalt.shopify_checkout_identity_v2
     SET checkout_status='OPEN', updated_at=now()-interval '2 hours'
   WHERE shopify_connection_id=v_store_b
     AND shopify_checkout_token='eligibility-shared-token';
  PERFORM henvalt.refresh_shopify_checkout_recovery_candidates_v2(interval '1 hour',100);
  IF NOT EXISTS (
    SELECT 1 FROM henvalt.shopify_checkout_recovery_candidate_v2
    WHERE shopify_connection_id=v_store_b
      AND checkout_token='eligibility-shared-token'
      AND state='CHECKOUT_CLOSED'
  ) THEN
    RAISE EXCEPTION 'Terminal closed checkout candidate was resurrected by refresh';
  END IF;

  -- A later order from Store B converts its own candidate; the exact Store A
  -- order cannot mark Store B converted before this second order arrives.
  v_hmac := encode(extensions.hmac(convert_to('{"shop_id":"2002","id":888002,"checkout_token":"eligibility-shared-token","customer":{"id":12345},"total_price":"75.00","currency":"GBP","financial_status":"paid","created_at":"2026-11-17T00:01:00Z"}','UTF8'),convert_to('synthetic-test-secret-never-used-in-production','UTF8'),'sha256'),'base64');
  SELECT * INTO v_receipt FROM henvalt.accept_shopify_webhook_v2(
    v_token_b,v_hmac,
    encode(convert_to('{"shop_id":"2002","id":888002,"checkout_token":"eligibility-shared-token","customer":{"id":12345},"total_price":"75.00","currency":"GBP","financial_status":"paid","created_at":"2026-11-17T00:01:00Z"}','UTF8'),'base64'),
    'store-b.myshopify.com','orders/create','eligibility-order-b','eligibility-order-event-b'
  );
  IF v_receipt.accepted IS DISTINCT FROM true THEN RAISE EXCEPTION 'Store B order receipt rejected'; END IF;
  v_result := henvalt.project_verified_shopify_order_v2(
    v_token_b,'eligibility-order-b',
    encode(convert_to('{"shop_id":"2002","id":888002,"checkout_token":"eligibility-shared-token","customer":{"id":12345},"total_price":"75.00","currency":"GBP","financial_status":"paid","created_at":"2026-11-17T00:01:00Z"}','UTF8'),'base64')
  );
  IF v_result->>'checkout_match_status'<>'MATCHED' THEN RAISE EXCEPTION 'Store B order did not match its own checkout'; END IF;
  PERFORM henvalt.refresh_shopify_checkout_recovery_candidates_v2(interval '1 hour',100);
  IF NOT EXISTS (
    SELECT 1 FROM henvalt.shopify_checkout_recovery_candidate_v2
    WHERE shopify_connection_id=v_store_b
      AND checkout_token='eligibility-shared-token'
      AND state='CONVERTED'
  ) THEN RAISE EXCEPTION 'Store B candidate was not marked converted by its own order'; END IF;

  -- A separate open checkout becomes terminal when its exact store is deactivated.
  DECLARE
    v_inactive_checkout text := '{"shop_id":"2002","id":777002,"token":"eligibility-inactive-store-token","customer":{"id":12346},"total_price":"50.00","currency":"GBP","completed_at":null}';
  BEGIN
    v_hmac := encode(extensions.hmac(convert_to(v_inactive_checkout,'UTF8'),convert_to('synthetic-test-secret-never-used-in-production','UTF8'),'sha256'),'base64');
    SELECT * INTO v_receipt FROM henvalt.accept_shopify_webhook_v2(
      v_token_b,v_hmac,encode(convert_to(v_inactive_checkout,'UTF8'),'base64'),
      'store-b.myshopify.com','checkouts/create','eligibility-checkout-inactive-b','eligibility-event-inactive-b'
    );
    IF v_receipt.accepted IS DISTINCT FROM true THEN RAISE EXCEPTION 'Inactive-state checkout receipt rejected'; END IF;
    v_result := henvalt.project_verified_shopify_checkout_v2(
      v_token_b,'eligibility-checkout-inactive-b',encode(convert_to(v_inactive_checkout,'UTF8'),'base64')
    );
    IF v_result->>'status'<>'OPEN' THEN RAISE EXCEPTION 'Inactive-state checkout projection failed: %',v_result; END IF;
    UPDATE henvalt.shopify_checkout_identity_v2
       SET updated_at=now()-interval '2 hours'
     WHERE shopify_connection_id=v_store_b AND shopify_checkout_token='eligibility-inactive-store-token';
    PERFORM henvalt.refresh_shopify_checkout_recovery_candidates_v2(interval '1 hour',100);
    UPDATE henvalt.shopify_connections SET active=false WHERE id=v_store_b;
    v_result := henvalt.refresh_shopify_checkout_recovery_candidates_v2(interval '1 hour',100);
    IF v_result->>'accepted'<>'true' THEN RAISE EXCEPTION 'Inactive-store candidate refresh failed: %',v_result; END IF;
    IF NOT EXISTS (
      SELECT 1 FROM henvalt.shopify_checkout_recovery_candidate_v2
       WHERE shopify_connection_id=v_store_b
         AND checkout_token='eligibility-inactive-store-token'
         AND state='STORE_INACTIVE'
    ) THEN RAISE EXCEPTION 'Inactive store candidate was not terminalized'; END IF;
    UPDATE henvalt.shopify_connections SET active=true WHERE id=v_store_b;
    PERFORM henvalt.refresh_shopify_checkout_recovery_candidates_v2(interval '1 hour',100);
    IF NOT EXISTS (
      SELECT 1 FROM henvalt.shopify_checkout_recovery_candidate_v2
       WHERE shopify_connection_id=v_store_b
         AND checkout_token='eligibility-inactive-store-token'
         AND state='STORE_INACTIVE'
    ) THEN RAISE EXCEPTION 'Reactivated store resurrected a terminal candidate'; END IF;
  END;
END;
$eligibility_v2$;

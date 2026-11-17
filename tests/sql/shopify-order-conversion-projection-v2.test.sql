-- Exact-store order-to-checkout conversion suppression regression.
-- Runs after checkout projection V2 in disposable PostgreSQL.
\set ON_ERROR_STOP on
DO $order_v2$
DECLARE
  v_tenant uuid := '00000000-0000-4000-8000-000000000001';
  v_store_a uuid;
  v_store_b uuid;
  v_token_a text := repeat('b',64);
  v_token_b text := repeat('c',64);
  v_body_a text := '{"shop_id":"1001","id":987654,"checkout_token":"shared-checkout-token","customer":{"id":12345},"total_price":"125.50","currency":"USD","financial_status":"pending","created_at":"2026-11-16T17:00:00Z"}';
  v_body_b text := '{"shop_id":"2002","id":987654,"checkout_token":"shared-checkout-token","customer":{"id":12345},"total_price":"75.00","currency":"GBP","financial_status":"paid","created_at":"2026-11-16T17:01:00Z"}';
  v_hmac text;
  v_result record;
  v_projection jsonb;
  v_count_a integer;
  v_count_b integer;
BEGIN
  SELECT id INTO v_store_a FROM henvalt.shopify_connections WHERE shop_domain='store-a.myshopify.com';
  SELECT id INTO v_store_b FROM henvalt.shopify_connections WHERE shop_domain='store-b.myshopify.com';
  IF v_store_a IS NULL OR v_store_b IS NULL THEN
    RAISE EXCEPTION 'Order V2 test requires both synthetic stores';
  END IF;
  UPDATE henvalt.shopify_connections SET active=true WHERE id IN (v_store_a,v_store_b);

  v_hmac := encode(
    extensions.hmac(convert_to(v_body_a,'UTF8'),convert_to('synthetic-test-secret-never-used-in-production','UTF8'),'sha256'),
    'base64'
  );
  SELECT * INTO v_result FROM henvalt.accept_shopify_webhook_v2(
    v_token_a,v_hmac,encode(convert_to(v_body_a,'UTF8'),'base64'),
    'store-a.myshopify.com','orders/create','order-delivery-a','order-event-a'
  );
  IF v_result.accepted IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'Store A order webhook was not verified: %',row_to_json(v_result);
  END IF;
  v_projection := henvalt.project_verified_shopify_order_v2(
    v_token_a,'order-delivery-a',encode(convert_to(v_body_a,'UTF8'),'base64')
  );
  IF v_projection->>'accepted'<>'true' OR v_projection->>'checkout_match_status'<>'MATCHED' THEN
    RAISE EXCEPTION 'Store A order conversion did not match its checkout: %',v_projection;
  END IF;

  v_hmac := encode(
    extensions.hmac(convert_to(v_body_b,'UTF8'),convert_to('synthetic-test-secret-never-used-in-production','UTF8'),'sha256'),
    'base64'
  );
  SELECT * INTO v_result FROM henvalt.accept_shopify_webhook_v2(
    v_token_b,v_hmac,encode(convert_to(v_body_b,'UTF8'),'base64'),
    'store-b.myshopify.com','orders/create','order-delivery-b','order-event-b'
  );
  IF v_result.accepted IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'Store B order webhook was not verified: %',row_to_json(v_result);
  END IF;
  v_projection := henvalt.project_verified_shopify_order_v2(
    v_token_b,'order-delivery-b',encode(convert_to(v_body_b,'UTF8'),'base64')
  );
  IF v_projection->>'accepted'<>'true' OR v_projection->>'checkout_match_status'<>'MATCHED' THEN
    RAISE EXCEPTION 'Store B order conversion did not match its checkout: %',v_projection;
  END IF;

  SELECT count(*) INTO v_count_a FROM henvalt.shopify_order_identity_v2
  WHERE shopify_connection_id=v_store_a AND shopify_order_id='987654'
    AND checkout_token='shared-checkout-token' AND financial_status='pending';
  SELECT count(*) INTO v_count_b FROM henvalt.shopify_order_identity_v2
  WHERE shopify_connection_id=v_store_b AND shopify_order_id='987654'
    AND checkout_token='shared-checkout-token' AND financial_status='paid';
  IF v_count_a<>1 OR v_count_b<>1 THEN
    RAISE EXCEPTION 'Same order ID was not isolated by exact store: A %, B %',v_count_a,v_count_b;
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM henvalt.shopify_checkout_identity_v2
    WHERE shopify_connection_id=v_store_a AND shopify_checkout_token='shared-checkout-token'
      AND checkout_status='COMPLETED'
  ) OR NOT EXISTS (
    SELECT 1 FROM henvalt.shopify_checkout_identity_v2
    WHERE shopify_connection_id=v_store_b AND shopify_checkout_token='shared-checkout-token'
      AND checkout_status='COMPLETED'
  ) THEN
    RAISE EXCEPTION 'Order creation did not mark only its exact-store checkout completed';
  END IF;

  -- A valid order without checkout_token is recorded, but cannot mutate a checkout.
  v_body_a := '{"shop_id":"1001","id":987655,"customer":{"id":12345},"total_price":"10.00","currency":"USD","financial_status":"pending"}';
  v_hmac := encode(
    extensions.hmac(convert_to(v_body_a,'UTF8'),convert_to('synthetic-test-secret-never-used-in-production','UTF8'),'sha256'),
    'base64'
  );
  SELECT * INTO v_result FROM henvalt.accept_shopify_webhook_v2(
    v_token_a,v_hmac,encode(convert_to(v_body_a,'UTF8'),'base64'),
    'store-a.myshopify.com','orders/create','order-delivery-no-token','order-event-no-token'
  );
  v_projection := henvalt.project_verified_shopify_order_v2(
    v_token_a,'order-delivery-no-token',encode(convert_to(v_body_a,'UTF8'),'base64')
  );
  IF v_projection->>'accepted'<>'true' OR v_projection->>'checkout_match_status'<>'NO_CHECKOUT_TOKEN' THEN
    RAISE EXCEPTION 'Order without checkout token was not safely recorded: %',v_projection;
  END IF;
END;
$order_v2$;


-- Order lifecycle updates must refresh financial and cancellation state.
DO $order_lifecycle_v2$
DECLARE
  v_token text:=repeat('b',64);
  v_body text;
  v_hmac text;
  v_result record;
  v_projection jsonb;
  v_order_id uuid;
BEGIN
  v_body:='{"shop_id":"1001","id":987654,"checkout_token":"shared-checkout-token","customer":{"id":12345},"total_price":"125.50","currency":"USD","financial_status":"paid","created_at":"2026-11-16T17:00:00Z","updated_at":"2026-11-17T10:00:00Z"}';
  v_hmac:=encode(extensions.hmac(convert_to(v_body,'UTF8'),convert_to('synthetic-test-secret-never-used-in-production','UTF8'),'sha256'),'base64');
  SELECT * INTO v_result FROM henvalt.accept_shopify_webhook_v2(
    v_token,v_hmac,encode(convert_to(v_body,'UTF8'),'base64'),
    'store-a.myshopify.com','orders/paid','order-paid-update-a','order-paid-event-a'
  );
  IF v_result.accepted IS DISTINCT FROM true THEN RAISE EXCEPTION 'Order paid update receipt rejected: %',row_to_json(v_result); END IF;
  v_projection:=henvalt.project_verified_shopify_order_v2(v_token,'order-paid-update-a',encode(convert_to(v_body,'UTF8'),'base64'));
  IF v_projection->>'accepted'<>'true' THEN RAISE EXCEPTION 'Order paid update not projected: %',v_projection; END IF;

  SELECT id INTO v_order_id FROM henvalt.shopify_order_identity_v2
   WHERE shopify_connection_id=(SELECT id FROM henvalt.shopify_connections WHERE shop_domain='store-a.myshopify.com')
     AND shopify_order_id='987654' AND financial_status='paid';
  IF v_order_id IS NULL THEN RAISE EXCEPTION 'Order financial status did not update to paid'; END IF;

  v_body:='{"shop_id":"1001","id":987654,"financial_status":"voided","cancelled_at":"2026-11-17T10:30:00Z","updated_at":"2026-11-17T10:31:00Z"}';
  v_hmac:=encode(extensions.hmac(convert_to(v_body,'UTF8'),convert_to('synthetic-test-secret-never-used-in-production','UTF8'),'sha256'),'base64');
  SELECT * INTO v_result FROM henvalt.accept_shopify_webhook_v2(
    v_token,v_hmac,encode(convert_to(v_body,'UTF8'),'base64'),
    'store-a.myshopify.com','orders/cancelled','order-cancelled-update-a','order-cancelled-event-a'
  );
  IF v_result.accepted IS DISTINCT FROM true THEN RAISE EXCEPTION 'Order cancellation receipt rejected: %',row_to_json(v_result); END IF;
  v_projection:=henvalt.project_verified_shopify_order_v2(v_token,'order-cancelled-update-a',encode(convert_to(v_body,'UTF8'),'base64'));
  IF v_projection->>'accepted'<>'true' THEN RAISE EXCEPTION 'Order cancellation not projected: %',v_projection; END IF;
  IF NOT EXISTS(
    SELECT 1 FROM henvalt.shopify_order_identity_v2
    WHERE id=v_order_id AND financial_status='voided' AND cancelled_at IS NOT NULL
      AND checkout_token='shared-checkout-token'
  ) THEN RAISE EXCEPTION 'Order cancellation did not preserve exact-store checkout lineage and update state'; END IF;
END;
$order_lifecycle_v2$;

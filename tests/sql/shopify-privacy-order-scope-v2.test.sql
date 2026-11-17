\set ON_ERROR_STOP on

BEGIN;

DO $test$
DECLARE
  v_a uuid;
  v_b uuid;
  v_count integer;
  v_bad record;
  v_body text;
  v_hmac text;
BEGIN
  SELECT id INTO v_a
  FROM henvalt.shopify_privacy_webhook_deliveries
  WHERE app_key='test_app' AND shop_domain='store-a.myshopify.com'
    AND webhook_id='privacy-delivery-001';
  SELECT id INTO v_b
  FROM henvalt.shopify_privacy_webhook_deliveries
  WHERE app_key='test_app' AND shop_domain='store-b.myshopify.com'
    AND webhook_id='privacy-delivery-001';

  IF v_a IS NULL OR v_b IS NULL OR v_a = v_b THEN
    RAISE EXCEPTION 'expected two exact-store privacy receipts';
  END IF;

  SELECT count(*) INTO v_count
  FROM henvalt.shopify_privacy_webhook_order_scope_v2
  WHERE receipt_id=v_a AND scope_kind='REQUESTED';
  IF v_count <> 3 OR NOT EXISTS (
    SELECT 1 FROM henvalt.shopify_privacy_webhook_order_scope_v2
    WHERE receipt_id=v_a AND scope_kind='REQUESTED' AND shopify_order_id='299938' AND ordinal=1
  ) THEN
    RAISE EXCEPTION 'Store A requested order scope was not preserved in order';
  END IF;

  SELECT count(*) INTO v_count
  FROM henvalt.shopify_privacy_webhook_order_scope_v2
  WHERE receipt_id=v_b AND scope_kind='REQUESTED';
  IF v_count <> 3 THEN
    RAISE EXCEPTION 'Store B requested order scope missing';
  END IF;

  IF EXISTS (
    SELECT 1 FROM henvalt.shopify_privacy_webhook_order_scope_v2 a
    JOIN henvalt.shopify_privacy_webhook_order_scope_v2 b
      ON b.scope_kind=a.scope_kind AND b.shopify_order_id=a.shopify_order_id
     AND b.receipt_id=v_b
    WHERE a.receipt_id=v_a
  ) IS NOT TRUE THEN
    RAISE EXCEPTION 'test fixture expected same order IDs across stores to demonstrate isolation';
  END IF;

  IF has_table_privilege('anon','henvalt.shopify_privacy_webhook_order_scope_v2','SELECT')
     OR has_table_privilege('authenticated','henvalt.shopify_privacy_webhook_order_scope_v2','SELECT')
     OR has_table_privilege('service_role','henvalt.shopify_privacy_webhook_order_scope_v2','SELECT') IS NOT TRUE THEN
    RAISE EXCEPTION 'privacy order scope privileges are not service-only';
  END IF;

  v_body := '{"shop_domain":"store-a.myshopify.com","shop_id":"1001","customer":{"id":12345},"data_request":{"id":98766},"orders_requested":[1,"2",1]}';
  v_hmac := encode(extensions.hmac(convert_to(v_body,'UTF8'),convert_to('synthetic-test-secret-never-used-in-production','UTF8'),'sha256'),'base64');
  SELECT * INTO v_bad FROM henvalt.accept_shopify_privacy_webhook_v2(
    'test_app','test-client-id',v_hmac,encode(convert_to(v_body,'UTF8'),'base64'),
    'store-a.myshopify.com','customers/data_request','privacy-duplicate-order-id'
  );
  IF v_bad.accepted IS DISTINCT FROM false OR v_bad.rejection_code <> 'INVALID_ORDER_SCOPE' THEN
    RAISE EXCEPTION 'duplicate order IDs were not rejected';
  END IF;

  v_body := '{"shop_domain":"store-a.myshopify.com","shop_id":"1001","customer":{"id":12345},"data_request":{"id":98767},"orders_requested":[0]}';
  v_hmac := encode(extensions.hmac(convert_to(v_body,'UTF8'),convert_to('synthetic-test-secret-never-used-in-production','UTF8'),'sha256'),'base64');
  SELECT * INTO v_bad FROM henvalt.accept_shopify_privacy_webhook_v2(
    'test_app','test-client-id',v_hmac,encode(convert_to(v_body,'UTF8'),'base64'),
    'store-a.myshopify.com','customers/data_request','privacy-zero-order-id'
  );
  IF v_bad.accepted IS DISTINCT FROM false OR v_bad.rejection_code <> 'INVALID_ORDER_SCOPE' THEN
    RAISE EXCEPTION 'zero order ID was not rejected';
  END IF;

  v_body := '{"shop_domain":"store-a.myshopify.com","shop_id":"1001","customer":{"id":12345},"orders_to_redact":[299938,280263,220458]}';
  v_hmac := encode(extensions.hmac(convert_to(v_body,'UTF8'),convert_to('synthetic-test-secret-never-used-in-production','UTF8'),'sha256'),'base64');
  SELECT * INTO v_bad FROM henvalt.accept_shopify_privacy_webhook_v2(
    'test_app','test-client-id',v_hmac,encode(convert_to(v_body,'UTF8'),'base64'),
    'store-a.myshopify.com','customers/redact','privacy-redact-order-scope'
  );
  IF v_bad.accepted IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'valid customers/redact order scope was rejected: %', row_to_json(v_bad);
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM henvalt.shopify_privacy_webhook_deliveries r
    JOIN henvalt.shopify_privacy_webhook_order_scope_v2 o ON o.receipt_id=r.id
    WHERE r.shop_domain='store-a.myshopify.com'
      AND r.webhook_id='privacy-redact-order-scope'
      AND o.scope_kind='TO_REDACT'
      AND o.shopify_order_id='299938'
  ) THEN
    RAISE EXCEPTION 'customers/redact order scope not persisted';
  END IF;
END;
$test$;

ROLLBACK;

SELECT 'privacy order scope tests passed' AS result;

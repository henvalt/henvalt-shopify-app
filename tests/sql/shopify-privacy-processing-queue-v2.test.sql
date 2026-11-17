\set ON_ERROR_STOP on

DO $test$
DECLARE
  v_a_id uuid;
  v_b_id uuid;
  v_unlinked_id uuid;
  v_a record;
  v_b record;
  v_retry record;
  v_ok boolean;
BEGIN
  SELECT id INTO v_a_id
  FROM henvalt.shopify_privacy_webhook_deliveries
  WHERE app_key = 'test_app'
    AND shop_domain = 'store-a.myshopify.com'
    AND webhook_id = 'privacy-delivery-001';

  SELECT id INTO v_b_id
  FROM henvalt.shopify_privacy_webhook_deliveries
  WHERE app_key = 'test_app'
    AND shop_domain = 'store-b.myshopify.com'
    AND webhook_id = 'privacy-delivery-001';

  IF v_a_id IS NULL OR v_b_id IS NULL OR v_a_id = v_b_id THEN
    RAISE EXCEPTION 'expected distinct exact-store privacy receipts for Store A and Store B';
  END IF;

  IF (SELECT state FROM henvalt.shopify_privacy_processing_jobs_v2 WHERE receipt_id = v_a_id) <> 'READY'
     OR (SELECT state FROM henvalt.shopify_privacy_processing_jobs_v2 WHERE receipt_id = v_b_id) <> 'READY' THEN
    RAISE EXCEPTION 'linked privacy receipts were not enqueued as READY';
  END IF;

  SELECT * INTO v_a FROM henvalt.claim_shopify_privacy_request_v2(300);
  IF v_a.receipt_id IS DISTINCT FROM v_a_id
     OR v_a.connection_id IS DISTINCT FROM (
       SELECT id FROM henvalt.shopify_connections WHERE shop_domain = 'store-a.myshopify.com'
     )
     OR v_a.customer_id <> '12345'
     OR v_a.attempt_count <> 1 THEN
    RAISE EXCEPTION 'first privacy claim was not bound to Store A: %', row_to_json(v_a);
  END IF;

  SELECT * INTO v_b FROM henvalt.claim_shopify_privacy_request_v2(300);
  IF v_b.receipt_id IS DISTINCT FROM v_b_id
     OR v_b.connection_id IS DISTINCT FROM (
       SELECT id FROM henvalt.shopify_connections WHERE shop_domain = 'store-b.myshopify.com'
     )
     OR v_b.customer_id <> '12345' THEN
    RAISE EXCEPTION 'second privacy claim was not bound to Store B: %', row_to_json(v_b);
  END IF;

  IF v_a.claim_token = v_b.claim_token THEN
    RAISE EXCEPTION 'privacy claim tokens must be unique';
  END IF;

  IF EXISTS (
    SELECT 1 FROM henvalt.shopify_privacy_processing_jobs_v2
    WHERE receipt_id = v_a_id AND claim_token_sha256 = v_a.claim_token
  ) THEN
    RAISE EXCEPTION 'raw privacy claim token was persisted instead of its digest';
  END IF;

  v_ok := henvalt.complete_shopify_privacy_request_v2(v_a_id, v_a.claim_token, false);
  IF v_ok IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'privacy request completed without processor confirmation';
  END IF;

  v_ok := henvalt.complete_shopify_privacy_request_v2(v_a_id, v_a.claim_token, true);
  IF v_ok IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'confirmed Store A privacy request did not complete';
  END IF;

  IF (SELECT customer_id FROM henvalt.shopify_privacy_webhook_deliveries WHERE id = v_a_id) IS NOT NULL
     OR (SELECT processing_status FROM henvalt.shopify_privacy_webhook_deliveries WHERE id = v_a_id) <> 'COMPLETED'
     OR (SELECT raw_body_sha256 FROM henvalt.shopify_privacy_webhook_deliveries WHERE id = v_a_id) IS NULL THEN
    RAISE EXCEPTION 'completed privacy receipt did not clear customer ID while retaining minimal digest';
  END IF;

  v_ok := henvalt.fail_shopify_privacy_request_v2(v_b_id, v_b.claim_token, 'EXPORT_DELIVERY_PENDING', true);
  IF v_ok IS DISTINCT FROM true
     OR (SELECT state FROM henvalt.shopify_privacy_processing_jobs_v2 WHERE receipt_id = v_b_id) <> 'READY' THEN
    RAISE EXCEPTION 'retryable privacy failure did not return job to READY';
  END IF;

  SELECT * INTO v_retry FROM henvalt.claim_shopify_privacy_request_v2(300);
  IF v_retry.receipt_id IS DISTINCT FROM v_b_id OR v_retry.attempt_count <> 2
     OR v_retry.claim_token = v_b.claim_token THEN
    RAISE EXCEPTION 'retry did not issue a fresh claim token and increment attempt count';
  END IF;

  v_ok := henvalt.fail_shopify_privacy_request_v2(v_b_id, v_retry.claim_token, 'POLICY_REVIEW_REQUIRED', false);
  IF v_ok IS DISTINCT FROM true
     OR (SELECT state FROM henvalt.shopify_privacy_processing_jobs_v2 WHERE receipt_id = v_b_id) <> 'FAILED'
     OR (SELECT processing_status FROM henvalt.shopify_privacy_webhook_deliveries WHERE id = v_b_id) <> 'FAILED' THEN
    RAISE EXCEPTION 'non-retryable privacy failure was not recorded as FAILED';
  END IF;

  INSERT INTO henvalt.shopify_privacy_webhook_deliveries (
    app_key, tenant_id, connection_id, shop_domain, topic, webhook_id,
    customer_id, raw_body_sha256, hmac_verified_at, processing_status
  ) VALUES (
    'test_app', NULL, NULL, 'unlinked.myshopify.com', 'customers/redact',
    'privacy-unlinked-001', '12345', repeat('a', 64), now(), 'REVIEW_REQUIRED'
  ) RETURNING id INTO v_unlinked_id;

  IF (SELECT state FROM henvalt.shopify_privacy_processing_jobs_v2 WHERE receipt_id = v_unlinked_id) <> 'REVIEW_REQUIRED' THEN
    RAISE EXCEPTION 'unlinked privacy receipt was not held for manual review';
  END IF;

  IF EXISTS (
    SELECT 1 FROM henvalt.claim_shopify_privacy_request_v2(300)
    WHERE receipt_id = v_unlinked_id
  ) THEN
    RAISE EXCEPTION 'unlinked privacy receipt was incorrectly claimed';
  END IF;
END;
$test$;

SELECT 'exact-store privacy queue tests passed' AS result;

-- Exact-store shop/redact stop integration test.
\set ON_ERROR_STOP on

BEGIN;

DO $shop_redact_stop_v2$
DECLARE
  v_tenant uuid := '00000000-0000-4000-8000-000000000001';
  v_store_a uuid;
  v_store_b uuid;
  v_receipt uuid;
  v_active_a boolean;
  v_active_b boolean;
  v_processing_status text;
  v_job_state text;
BEGIN
  SELECT id, active INTO v_store_a, v_active_a
  FROM henvalt.shopify_connections
  WHERE shop_domain = 'store-a.myshopify.com'
    AND tenant_id = v_tenant;

  SELECT id, active INTO v_store_b, v_active_b
  FROM henvalt.shopify_connections
  WHERE shop_domain = 'store-b.myshopify.com'
    AND tenant_id = v_tenant;

  IF v_store_a IS NULL OR v_store_b IS NULL
     OR v_active_a IS DISTINCT FROM true
     OR v_active_b IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'shop redact stop test requires two active synthetic stores';
  END IF;

  INSERT INTO henvalt.shopify_privacy_webhook_deliveries(
    app_key, tenant_id, connection_id, shop_domain, topic, webhook_id,
    customer_id, raw_body_sha256, hmac_verified_at, processing_status
  ) VALUES (
    'test_app', v_tenant, v_store_a, 'store-a.myshopify.com',
    'shop/redact', 'shop-redact-stop-store-a-2026-11-17',
    NULL, repeat('e',64), now(), 'REVIEW_REQUIRED'
  ) RETURNING id INTO v_receipt;

  SELECT active INTO v_active_a
  FROM henvalt.shopify_connections WHERE id = v_store_a AND tenant_id = v_tenant;
  SELECT active INTO v_active_b
  FROM henvalt.shopify_connections WHERE id = v_store_b AND tenant_id = v_tenant;

  SELECT processing_status INTO v_processing_status
  FROM henvalt.shopify_privacy_webhook_deliveries WHERE id = v_receipt;
  SELECT state INTO v_job_state
  FROM henvalt.shopify_privacy_processing_jobs_v2 WHERE receipt_id = v_receipt;

  IF v_active_a IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'shop/redact did not disable its exact store';
  END IF;
  IF v_active_b IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'shop/redact stop leaked into another store in the same tenant';
  END IF;
  IF v_processing_status <> 'PROCESSING' OR v_job_state <> 'READY' THEN
    RAISE EXCEPTION 'shop/redact receipt was not retained for privacy processing review';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM henvalt.shopify_privacy_webhook_deliveries
    WHERE id = v_receipt
      AND metadata->>'shop_redact_data_deleted' = 'false'
      AND metadata->>'shop_redact_requires_review' = 'true'
  ) THEN
    RAISE EXCEPTION 'shop/redact stop incorrectly represented deletion as complete';
  END IF;
END;
$shop_redact_stop_v2$;

ROLLBACK;

SELECT 'shopify_exact_store_shop_redact_stop_v2_passed' AS result;

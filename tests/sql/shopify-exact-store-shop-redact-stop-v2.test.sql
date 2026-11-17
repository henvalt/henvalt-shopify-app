-- Exact-store shop/redact stop integration test.
\set ON_ERROR_STOP on

BEGIN;

-- Earlier integration cases deliberately uninstall store B. Restore the
-- synthetic two-store fixture before testing the independent shop/redact path.
UPDATE henvalt.shopify_connections
SET active = true
WHERE tenant_id = '00000000-0000-4000-8000-000000000001'
  AND shop_domain IN ('store-a.myshopify.com', 'store-b.myshopify.com');

DO $shop_redact_stop_v2$
DECLARE
  v_tenant uuid := '00000000-0000-4000-8000-000000000001';
  v_store_a uuid;
  v_store_b uuid;
  v_receipt uuid;
  v_active_a boolean;
  v_active_b boolean;
  v_processing_status text;
  v_processed_at timestamptz;
  v_job_state text;
  v_old_oauth_state_blocked boolean := false;
  v_new_oauth_state_blocked boolean := false;
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

  -- This state predates shop/redact and must not be consumable afterwards.
  INSERT INTO henvalt.shopify_oauth_states(
    state_hash, shop_domain, expires_at, initiated_by_user_id, app_key
  ) VALUES (
    'shop-redact-stale-oauth-state', 'store-a.myshopify.com',
    now() + interval '10 minutes', v_tenant, 'test_app'
  );

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

  SELECT processing_status, processed_at INTO v_processing_status, v_processed_at
  FROM henvalt.shopify_privacy_webhook_deliveries WHERE id = v_receipt;
  SELECT state INTO v_job_state
  FROM henvalt.shopify_privacy_processing_jobs_v2 WHERE receipt_id = v_receipt;

  IF NOT EXISTS (
    SELECT 1 FROM henvalt.shopify_redacted_store_tombstones_v2
    WHERE app_key = 'test_app'
      AND shop_domain = 'store-a.myshopify.com'
      AND tenant_id = v_tenant
      AND connection_id = v_store_a
      AND receipt_id = v_receipt
  ) THEN
    RAISE EXCEPTION 'verified shop/redact receipt did not create exact-store OAuth tombstone';
  END IF;

  BEGIN
    UPDATE henvalt.shopify_oauth_states
       SET consumed_at = now()
     WHERE state_hash = 'shop-redact-stale-oauth-state';
  EXCEPTION WHEN SQLSTATE '55000' THEN
    v_old_oauth_state_blocked := true;
  END;

  BEGIN
    INSERT INTO henvalt.shopify_oauth_states(
      state_hash, shop_domain, expires_at, initiated_by_user_id, app_key
    ) VALUES (
      'shop-redact-new-oauth-state', 'store-a.myshopify.com',
      now() + interval '10 minutes', v_tenant, 'test_app'
    );
  EXCEPTION WHEN SQLSTATE '55000' THEN
    v_new_oauth_state_blocked := true;
  END;

  IF NOT v_old_oauth_state_blocked OR NOT v_new_oauth_state_blocked THEN
    RAISE EXCEPTION 'shop/redact did not block stale and new OAuth states';
  END IF;

  IF v_active_a IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'shop/redact did not disable its exact store';
  END IF;
  IF EXISTS (
    SELECT 1 FROM henvalt.shopify_redacted_store_tombstones_v2
    WHERE app_key = 'test_app' AND shop_domain = 'store-b.myshopify.com'
  ) THEN
    RAISE EXCEPTION 'shop/redact tombstone leaked into another store in the same tenant';
  END IF;
  IF v_active_b IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'shop/redact stop leaked into another store in the same tenant';
  END IF;
  IF v_processing_status <> 'PROCESSING' OR v_job_state <> 'READY'
     OR v_processed_at IS NOT NULL THEN
    RAISE EXCEPTION 'shop/redact receipt was not retained for privacy processing review';
  END IF;
END;
$shop_redact_stop_v2$;

ROLLBACK;

SELECT 'shopify_exact_store_shop_redact_stop_v2_passed' AS result;

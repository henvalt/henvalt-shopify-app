\set ON_ERROR_STOP on

DO $test$
DECLARE
  v_receipt record;
  v_artifact_id uuid;
  v_connection_b uuid;
  v_role_ok boolean;
BEGIN
  SELECT r.id, r.tenant_id, r.connection_id, r.app_key, r.shop_domain
    INTO v_receipt
  FROM henvalt.shopify_privacy_webhook_deliveries r
  WHERE r.app_key = 'test_app'
    AND r.shop_domain = 'store-a.myshopify.com'
    AND r.webhook_id = 'privacy-delivery-001';

  IF v_receipt.id IS NULL THEN
    RAISE EXCEPTION 'missing Store A privacy receipt fixture';
  END IF;

  SELECT id INTO v_connection_b
  FROM henvalt.shopify_connections
  WHERE shop_domain = 'store-b.myshopify.com';

  INSERT INTO henvalt.shopify_privacy_export_artifacts_v2 (
    receipt_id, tenant_id, connection_id, app_key, shop_domain,
    generation_id, object_key, sha256_hex, byte_count,
    completeness_status, manifest_summary, state, expires_at
  ) VALUES (
    v_receipt.id, v_receipt.tenant_id, v_receipt.connection_id,
    v_receipt.app_key, v_receipt.shop_domain,
    gen_random_uuid(), gen_random_uuid()::text || '.json',
    repeat('a', 64), 128, 'COMPLETE_FOR_MERCHANT_REVIEW',
    jsonb_build_object(
      'schema_version', 1,
      'categories', jsonb_build_array(
        jsonb_build_object('name', 'sessions', 'count', 0)
      )
    ),
    'STAGED', now() + interval '1 day'
  ) RETURNING id INTO v_artifact_id;

  INSERT INTO henvalt.shopify_privacy_delivery_evidence_v2 (
    receipt_id, tenant_id, connection_id, app_key, shop_domain,
    artifact_id, event_type, outcome_code, correlation_id
  ) VALUES (
    v_receipt.id, v_receipt.tenant_id, v_receipt.connection_id,
    v_receipt.app_key, v_receipt.shop_domain,
    v_artifact_id, 'ARTIFACT_GENERATED', 'STAGED', gen_random_uuid()
  );

  IF NOT EXISTS (
    SELECT 1 FROM henvalt.shopify_privacy_export_artifacts_v2
    WHERE id = v_artifact_id
      AND state = 'STAGED'
      AND bucket_id = 'henvalt-privacy-exports-v2'
  ) THEN
    RAISE EXCEPTION 'valid staged artifact metadata was not persisted';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM henvalt.shopify_privacy_delivery_evidence_v2
    WHERE artifact_id = v_artifact_id
      AND event_type = 'ARTIFACT_GENERATED'
  ) THEN
    RAISE EXCEPTION 'artifact evidence event was not persisted';
  END IF;

  IF has_table_privilege('anon', 'henvalt.shopify_privacy_export_artifacts_v2', 'SELECT')
     OR has_table_privilege('authenticated', 'henvalt.shopify_privacy_export_artifacts_v2', 'SELECT')
     OR NOT has_table_privilege('service_role', 'henvalt.shopify_privacy_export_artifacts_v2', 'SELECT')
     OR has_table_privilege('anon', 'henvalt.shopify_privacy_delivery_evidence_v2', 'SELECT')
     OR has_table_privilege('authenticated', 'henvalt.shopify_privacy_delivery_evidence_v2', 'SELECT')
     OR has_table_privilege('service_role', 'henvalt.shopify_privacy_delivery_evidence_v2', 'UPDATE')
     OR has_table_privilege('service_role', 'henvalt.shopify_privacy_delivery_evidence_v2', 'DELETE') THEN
    RAISE EXCEPTION 'artifact/evidence table privileges are not service-only and append-only';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'henvalt'
      AND c.relname = 'shopify_privacy_export_artifacts_v2'
      AND c.relrowsecurity AND c.relforcerowsecurity
  ) OR NOT EXISTS (
    SELECT 1 FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'henvalt'
      AND c.relname = 'shopify_privacy_delivery_evidence_v2'
      AND c.relrowsecurity AND c.relforcerowsecurity
  ) THEN
    RAISE EXCEPTION 'RLS and FORCE RLS must be enabled for both metadata tables';
  END IF;

  -- Same tenant does not permit crossing the receipt's store binding.
  BEGIN
    INSERT INTO henvalt.shopify_privacy_export_artifacts_v2 (
      receipt_id, tenant_id, connection_id, app_key, shop_domain,
      generation_id, object_key, sha256_hex, byte_count,
      completeness_status, manifest_summary, state, expires_at
    ) VALUES (
      v_receipt.id, v_receipt.tenant_id, v_connection_b,
      v_receipt.app_key, 'store-b.myshopify.com',
      gen_random_uuid(), gen_random_uuid()::text || '.json',
      repeat('b', 64), 64, 'COMPLETE_FOR_MERCHANT_REVIEW',
      '{}'::jsonb, 'STAGED', now() + interval '1 day'
    );
    RAISE EXCEPTION 'cross-store artifact binding was accepted';
  EXCEPTION WHEN foreign_key_violation THEN
    NULL;
  END;

  -- Incomplete or review-required export data can never be marked available.
  BEGIN
    INSERT INTO henvalt.shopify_privacy_export_artifacts_v2 (
      receipt_id, tenant_id, connection_id, app_key, shop_domain,
      generation_id, object_key, sha256_hex, byte_count,
      completeness_status, manifest_summary, state, expires_at
    ) VALUES (
      v_receipt.id, v_receipt.tenant_id, v_receipt.connection_id,
      v_receipt.app_key, v_receipt.shop_domain,
      gen_random_uuid(), gen_random_uuid()::text || '.json',
      repeat('c', 64), 64, 'REVIEW_REQUIRED',
      '{}'::jsonb, 'AVAILABLE', now() + interval '1 day'
    );
    RAISE EXCEPTION 'review-required artifact was marked available';
  EXCEPTION WHEN check_violation THEN
    NULL;
  END;
END;
$test$;

SELECT 'privacy export artifact registry tests passed' AS result;

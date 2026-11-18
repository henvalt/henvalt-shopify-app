\set ON_ERROR_STOP on

DO $test$
DECLARE
  v_receipt record;
  v_artifact_id uuid;
  v_claim record;
  v_wrong_claim boolean;
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

  INSERT INTO henvalt.shopify_privacy_export_artifacts_v2 (
    receipt_id, tenant_id, connection_id, app_key, shop_domain,
    generation_id, object_key, sha256_hex, byte_count,
    completeness_status, manifest_summary, state, expires_at
  ) VALUES (
    v_receipt.id, v_receipt.tenant_id, v_receipt.connection_id,
    v_receipt.app_key, v_receipt.shop_domain,
    gen_random_uuid(), gen_random_uuid()::text || '.json',
    repeat('d', 64), 128, 'COMPLETE_FOR_MERCHANT_REVIEW',
    jsonb_build_object('schema_version', 1, 'categories', jsonb_build_array()),
    'AVAILABLE', now() - interval '1 minute'
  ) RETURNING id INTO v_artifact_id;

  SELECT * INTO v_claim
  FROM henvalt.claim_shopify_privacy_export_purge_v2(300);

  IF v_claim.artifact_id IS DISTINCT FROM v_artifact_id
     OR v_claim.bucket_id <> 'henvalt-privacy-exports-v2'
     OR v_claim.attempt_count <> 1
     OR v_claim.claim_token IS NULL THEN
    RAISE EXCEPTION 'expired artifact was not claimed with expected binding';
  END IF;

  IF henvalt.confirm_shopify_privacy_export_purged_v2(
    v_artifact_id, repeat('0', 64), true
  ) THEN
    RAISE EXCEPTION 'wrong purge token was accepted';
  END IF;

  IF henvalt.confirm_shopify_privacy_export_purged_v2(
    v_artifact_id, v_claim.claim_token, false
  ) THEN
    RAISE EXCEPTION 'purge completed without object-absence confirmation';
  END IF;

  IF NOT henvalt.fail_shopify_privacy_export_purge_v2(
    v_artifact_id, v_claim.claim_token, 'STORAGE_DELETE_UNCONFIRMED'
  ) THEN
    RAISE EXCEPTION 'valid purge failure was not recorded';
  END IF;

  SELECT * INTO v_claim
  FROM henvalt.claim_shopify_privacy_export_purge_v2(300);

  IF v_claim.artifact_id IS DISTINCT FROM v_artifact_id
     OR v_claim.attempt_count <> 2 THEN
    RAISE EXCEPTION 'failed purge did not remain retryable';
  END IF;

  IF NOT henvalt.confirm_shopify_privacy_export_purged_v2(
    v_artifact_id, v_claim.claim_token, true
  ) THEN
    RAISE EXCEPTION 'valid confirmed purge did not complete';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM henvalt.shopify_privacy_export_artifacts_v2
    WHERE id = v_artifact_id AND state = 'PURGED'
      AND purged_at IS NOT NULL
      AND purge_claim_token_sha256 IS NULL
      AND purge_lease_until IS NULL
  ) THEN
    RAISE EXCEPTION 'purged artifact metadata was not tombstoned';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM henvalt.shopify_privacy_delivery_evidence_v2
    WHERE artifact_id = v_artifact_id AND event_type = 'ARTIFACT_PURGED'
  ) OR NOT EXISTS (
    SELECT 1 FROM henvalt.shopify_privacy_delivery_evidence_v2
    WHERE artifact_id = v_artifact_id
      AND event_type = 'ARTIFACT_PURGE_FAILED'
      AND outcome_code = 'STORAGE_DELETE_UNCONFIRMED'
  ) THEN
    RAISE EXCEPTION 'purge evidence trail is incomplete';
  END IF;

  IF has_function_privilege('anon',
       'henvalt.claim_shopify_privacy_export_purge_v2(integer)', 'EXECUTE')
     OR has_function_privilege('authenticated',
       'henvalt.confirm_shopify_privacy_export_purged_v2(uuid,text,boolean)', 'EXECUTE')
     OR NOT has_function_privilege('service_role',
       'henvalt.claim_shopify_privacy_export_purge_v2(integer)', 'EXECUTE') THEN
    RAISE EXCEPTION 'purge RPC grants are not service-only';
  END IF;
END;
$test$;

SELECT 'privacy export purge lifecycle tests passed' AS result;

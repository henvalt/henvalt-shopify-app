-- Exact-store customer redaction send guard integration tests.
\set ON_ERROR_STOP on

DO $redaction_guard_v2$
DECLARE
  v_tenant uuid := '00000000-0000-4000-8000-000000000001';
  v_store_a uuid;
  v_store_b uuid;
  v_customer_a uuid;
  v_customer_b uuid;
  v_opportunity_b uuid;
  v_intervention uuid;
  v_sender uuid;
  v_provider_key text;
  v_receipt uuid;
  v_claim record;
  v_guard jsonb;
  v_prepared jsonb;
  v_blocked boolean;
  v_permit_id uuid;
  v_step integer;
BEGIN
  SELECT id INTO v_store_a FROM henvalt.shopify_connections WHERE shop_domain='store-a.myshopify.com';
  SELECT id INTO v_store_b FROM henvalt.shopify_connections WHERE shop_domain='store-b.myshopify.com';
  IF v_store_a IS NULL OR v_store_b IS NULL THEN
    RAISE EXCEPTION 'redaction guard requires both synthetic store connections';
  END IF;

  -- The same external customer reference is intentionally present in both
  -- stores; only Store B receives the privacy guard.
  INSERT INTO henvalt.shopify_customer_identity_v2(
    tenant_id, shopify_connection_id, external_customer_reference
  ) VALUES (v_tenant, v_store_a, 'redaction-guard-customer-9001')
  RETURNING id INTO v_customer_a;

  INSERT INTO henvalt.shopify_customer_identity_v2(
    tenant_id, shopify_connection_id, external_customer_reference
  ) VALUES (v_tenant, v_store_b, 'redaction-guard-customer-9001')
  RETURNING id INTO v_customer_b;

  SELECT id INTO v_opportunity_b
  FROM henvalt.shopify_recovery_opportunity_v2
  WHERE tenant_id=v_tenant AND shopify_connection_id=v_store_b
  ORDER BY created_at DESC
  LIMIT 1;

  SELECT provider_account_key INTO v_provider_key
  FROM henvalt.shopify_mailer_provider_registry_v2
  WHERE tenant_id=v_tenant
  ORDER BY created_at DESC
  LIMIT 1;

  IF v_customer_a IS NULL OR v_customer_b IS NULL
     OR v_opportunity_b IS NULL OR v_provider_key IS NULL THEN
    RAISE EXCEPTION 'redaction guard prerequisites missing';
  END IF;

  SELECT steps.n INTO v_step
  FROM generate_series(1,10) AS steps(n)
  WHERE NOT EXISTS (
    SELECT 1 FROM henvalt.shopify_recovery_intervention_v2 i
    WHERE i.opportunity_id=v_opportunity_b AND i.step_number=candidate
  )
  ORDER BY steps.n
  LIMIT 1;
  IF v_step IS NULL THEN
    RAISE EXCEPTION 'no unused intervention step available for redaction guard test';
  END IF;

  INSERT INTO henvalt.shopify_recovery_intervention_v2(
    tenant_id, shopify_connection_id, opportunity_id, customer_identity_id,
    step_number, status, scheduled_at
  ) VALUES (
    v_tenant, v_store_b, v_opportunity_b, v_customer_b,
    v_step, 'READY_FOR_AUTHORIZATION', now()
  ) RETURNING id INTO v_intervention;

  INSERT INTO henvalt.shopify_sender_profiles_v2(
    tenant_id, shopify_connection_id, provider_account_key,
    from_email, from_name, status, verified_at
  ) VALUES (
    v_tenant, v_store_b, v_provider_key,
    'privacy-test@henvalt.invalid', 'HENVALT Test', 'ACTIVE', now()
  ) RETURNING id INTO v_sender;

  INSERT INTO henvalt.shopify_delivery_permits_v2(
    tenant_id, shopify_connection_id, intervention_id, customer_identity_id,
    provider_account_key, sender_profile_id, permit_token_sha256,
    recipient_fingerprint, expires_at
  ) VALUES (
    v_tenant, v_store_b, v_intervention, v_customer_b,
    v_provider_key, v_sender,
    encode(extensions.digest(convert_to(repeat('9',64),'UTF8'),'sha256'),'hex'),
    decode(repeat('ab',32),'hex'), now()+interval '3 minutes'
  ) RETURNING id INTO v_permit_id;

  INSERT INTO henvalt.shopify_privacy_webhook_deliveries(
    app_key, tenant_id, connection_id, shop_domain, topic, webhook_id,
    customer_id, raw_body_sha256, hmac_verified_at, processing_status
  ) VALUES (
    'test_app', v_tenant, v_store_b, 'store-b.myshopify.com',
    'customers/redact', 'redaction-guard-privacy-9001',
    'redaction-guard-customer-9001', repeat('f',64), now(), 'REVIEW_REQUIRED'
  ) RETURNING id INTO v_receipt;

  SELECT * INTO v_claim FROM henvalt.claim_shopify_privacy_request_v2(300);
  IF v_claim.receipt_id IS DISTINCT FROM v_receipt
     OR v_claim.connection_id IS DISTINCT FROM v_store_b
     OR v_claim.customer_id <> 'redaction-guard-customer-9001' THEN
    RAISE EXCEPTION 'redaction guard privacy receipt was not claimed with exact Store B identity';
  END IF;

  v_guard := henvalt.begin_shopify_customer_redaction_guard_v2(v_receipt, v_claim.claim_token);
  IF v_guard->>'guarded' <> 'true'
     OR v_guard->>'exact_store_scope_confirmed' <> 'true'
     OR v_guard->>'new_delivery_material_blocked' <> 'true'
     OR v_guard->>'safe_to_complete_privacy_request' <> 'false'
     OR v_guard->>'customer_data_deleted' <> 'false'
     OR v_guard->>'suppression_records_mutated' <> 'false'
     OR v_guard->>'provider_audit_records_mutated' <> 'false'
     OR v_guard->>'cost_reservations_mutated' <> 'false'
     OR v_guard->>'order_refund_attribution_fee_records_mutated' <> 'false' THEN
    RAISE EXCEPTION 'redaction guard did not return fail-closed preservation result: %', v_guard;
  END IF;

  v_prepared := henvalt.prepare_shopify_customer_redaction_send_stop_v2(v_receipt, v_claim.claim_token);
  IF v_prepared->>'prepared' <> 'true'
     OR v_prepared->>'exact_store_scope_confirmed' <> 'true'
     OR v_prepared->>'customer_data_deleted' <> 'false'
     OR v_prepared->>'safe_to_complete_privacy_request' <> 'false' THEN
    RAISE EXCEPTION 'post-commit redaction send-stop preparation failed: %', v_prepared;
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM henvalt.shopify_customer_redaction_guards_v2
    WHERE tenant_id=v_tenant AND shopify_connection_id=v_store_b
      AND customer_identity_id=v_customer_b AND receipt_id=v_receipt AND state='ACTIVE'
  ) THEN
    RAISE EXCEPTION 'Store B customer guard was not persisted';
  END IF;

  IF EXISTS (
    SELECT 1 FROM henvalt.shopify_customer_redaction_guards_v2
    WHERE tenant_id=v_tenant AND shopify_connection_id=v_store_a
      AND customer_identity_id=v_customer_a
  ) THEN
    RAISE EXCEPTION 'Store B privacy guard leaked to Store A with the same external customer reference';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM henvalt.shopify_delivery_permits_v2
    WHERE id=v_permit_id AND consumed_at IS NULL AND expires_at<=now()
  ) THEN
    RAISE EXCEPTION 'pre-existing unconsumed permit was not expired';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM henvalt.shopify_recovery_intervention_v2
    WHERE id=v_intervention AND status='CANCELLED'
  ) THEN
    RAISE EXCEPTION 'intervention without a send attempt was not cancelled';
  END IF;

  -- Both permit issuance and send-attempt creation must fail closed after
  -- guard activation, even when the caller has a valid service-role context.
  v_blocked := false;
  BEGIN
    INSERT INTO henvalt.shopify_delivery_permits_v2(
      tenant_id, shopify_connection_id, intervention_id, customer_identity_id,
      provider_account_key, sender_profile_id, permit_token_sha256,
      recipient_fingerprint, expires_at
    ) VALUES (
      v_tenant, v_store_b, v_intervention, v_customer_b,
      v_provider_key, v_sender,
      encode(extensions.digest(convert_to(repeat('8',64),'UTF8'),'sha256'),'hex'),
      decode(repeat('cd',32),'hex'), now()+interval '3 minutes'
    );
  EXCEPTION WHEN SQLSTATE '55000' THEN
    v_blocked := true;
  END;
  IF NOT v_blocked THEN
    RAISE EXCEPTION 'new delivery permit was allowed after redaction guard activation';
  END IF;

  v_blocked := false;
  BEGIN
    INSERT INTO henvalt.shopify_recovery_send_attempt_v2(
      tenant_id, shopify_connection_id, customer_identity_id, intervention_id,
      provider_account_key, idempotency_key, status
    ) VALUES (
      v_tenant, v_store_b, v_customer_b, v_intervention,
      v_provider_key, 'redaction-guard-blocked-attempt-9001', 'AUTHORIZED'
    );
  EXCEPTION WHEN SQLSTATE '55000' THEN
    v_blocked := true;
  END;
  IF NOT v_blocked THEN
    RAISE EXCEPTION 'new send attempt was allowed after redaction guard activation';
  END IF;

  IF henvalt.begin_shopify_customer_redaction_guard_v2(v_receipt, repeat('0',64))->>'guarded' <> 'false' THEN
    RAISE EXCEPTION 'redaction guard accepted a mismatched claim token';
  END IF;
END;
$redaction_guard_v2$;

SELECT 'shopify_customer_redaction_send_guard_v2_passed' AS result;

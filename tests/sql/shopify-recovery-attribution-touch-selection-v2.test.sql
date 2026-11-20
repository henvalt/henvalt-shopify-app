-- Exact-store checkout attribution touch selection and consumed-opportunity regression.
-- Runs after order conversion and recovery-opportunity integration fixtures in disposable PostgreSQL.
-- No production data, provider calls, customer messages, or billing actions.
\set ON_ERROR_STOP on

BEGIN;

DO $checkout_attribution_touch_v2$
DECLARE
  v_tenant uuid := '00000000-0000-4000-8000-000000000001';
  v_store_a uuid;
  v_store_b uuid;
  v_opp_a uuid;
  v_opp_b uuid;
  v_customer_a uuid;
  v_customer_b uuid;
  v_order_a uuid;
  v_order_b uuid;
  v_intervention_a1 uuid;
  v_intervention_a2 uuid;
  v_intervention_b1 uuid;
  v_intervention_b2 uuid;
  v_attempt_a1 uuid;
  v_attempt_a2 uuid;
  v_attempt_b1 uuid;
  v_attempt_b2 uuid;
  v_body text;
  v_hmac text;
  v_receipt record;
  v_projection jsonb;
  v_eval jsonb;
  v_provider_key text := 'henvalt-test-provider-account-0001';
BEGIN
  SELECT id INTO v_store_a FROM henvalt.shopify_connections WHERE shop_domain='store-a.myshopify.com';
  SELECT id INTO v_store_b FROM henvalt.shopify_connections WHERE shop_domain='store-b.myshopify.com';

  SELECT o.id,o.customer_identity_id INTO v_opp_a,v_customer_a
  FROM henvalt.shopify_recovery_opportunity_v2 o
  JOIN henvalt.shopify_checkout_recovery_candidate_v2 c
    ON c.id=o.candidate_id AND c.tenant_id=o.tenant_id AND c.shopify_connection_id=o.shopify_connection_id
  WHERE o.shopify_connection_id=v_store_a AND c.checkout_token='opportunity-shared-token';

  SELECT o.id,o.customer_identity_id INTO v_opp_b,v_customer_b
  FROM henvalt.shopify_recovery_opportunity_v2 o
  JOIN henvalt.shopify_checkout_recovery_candidate_v2 c
    ON c.id=o.candidate_id AND c.tenant_id=o.tenant_id AND c.shopify_connection_id=o.shopify_connection_id
  WHERE o.shopify_connection_id=v_store_b AND c.checkout_token='opportunity-shared-token';

  SELECT id INTO v_order_a FROM henvalt.shopify_order_identity_v2
  WHERE shopify_connection_id=v_store_a AND shopify_order_id='889001';

  IF v_store_a IS NULL OR v_store_b IS NULL OR v_opp_a IS NULL OR v_opp_b IS NULL
     OR v_customer_a IS NULL OR v_customer_b IS NULL OR v_order_a IS NULL THEN
    RAISE EXCEPTION 'Attribution touch fixture prerequisites missing';
  END IF;

  -- Store B gets its own paid order. The same checkout token and customer ID
  -- are deliberately reused across stores to prove exact-store isolation.
  v_body := '{"shop_id":"2002","id":889002,"checkout_token":"opportunity-shared-token","customer":{"id":12345},"total_price":"75.00","currency":"GBP","financial_status":"paid","created_at":"2026-11-17T00:02:00Z"}';
  v_hmac := encode(extensions.hmac(convert_to(v_body,'UTF8'),convert_to('synthetic-test-secret-never-used-in-production','UTF8'),'sha256'),'base64');
  SELECT * INTO v_receipt FROM henvalt.accept_shopify_webhook_v2(
    repeat('c',64),v_hmac,encode(convert_to(v_body,'UTF8'),'base64'),
    'store-b.myshopify.com','orders/create','attribution-order-b','attribution-order-b-event'
  );
  IF v_receipt.accepted IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'Store B attribution order receipt rejected: %',row_to_json(v_receipt);
  END IF;
  v_projection := henvalt.project_verified_shopify_order_v2(
    repeat('c',64),'attribution-order-b',encode(convert_to(v_body,'UTF8'),'base64')
  );
  IF v_projection->>'accepted'<>'true' OR v_projection->>'checkout_match_status'<>'MATCHED' THEN
    RAISE EXCEPTION 'Store B attribution order failed exact checkout match: %',v_projection;
  END IF;
  PERFORM henvalt.promote_shopify_checkout_recovery_candidates_v2(100);

  SELECT id INTO v_order_b FROM henvalt.shopify_order_identity_v2
  WHERE shopify_connection_id=v_store_b AND shopify_order_id='889002';
  IF v_order_b IS NULL THEN RAISE EXCEPTION 'Store B order projection row missing'; END IF;

  INSERT INTO henvalt.shopify_mailer_provider_registry_v2(
    tenant_id,provider_account_key,mailersend_domain_id,webhook_secret_ref,
    recipient_fingerprint_secret_ref,status
  ) VALUES(
    v_tenant,v_provider_key,'synthetic-test-domain','vault://synthetic-webhook-secret',
    'vault://synthetic-fingerprint-secret','ACTIVE'
  ) ON CONFLICT(provider_account_key) DO NOTHING;

  -- Satisfy the real cost-reservation boundary in this disposable transaction.
  -- All values are synthetic and rolled back at the end of this fixture.
  INSERT INTO henvalt.billing_accounts(
    tenant_id,status,test_mode,henvalt_percentage,usage_cap_amount,
    currency,monthly_email_limit,activated_at,updated_at
  ) VALUES(
    v_tenant,'ACTIVE',false,5,100,'USD',100,pg_catalog.now(),pg_catalog.now()
  )
  ON CONFLICT(tenant_id) DO UPDATE SET
    status='ACTIVE',test_mode=false,henvalt_percentage=5,
    usage_cap_amount=100,currency='USD',monthly_email_limit=100,
    activated_at=pg_catalog.now(),updated_at=pg_catalog.now();
  UPDATE henvalt.shopify_mailer_provider_registry_v2
     SET email_unit_cost_amount=0.001,email_unit_cost_currency='USD',status='ACTIVE'
   WHERE tenant_id=v_tenant AND provider_account_key=v_provider_key;

  -- Two eligible sends for the same checkout opportunity in each store.
  -- This is the representable multi-touch case: a checkout candidate is unique
  -- per store/token, while one opportunity can contain multiple sequence steps.
  INSERT INTO henvalt.shopify_recovery_intervention_v2(
    tenant_id,shopify_connection_id,opportunity_id,customer_identity_id,step_number,status,scheduled_at
  ) VALUES
    (v_tenant,v_store_a,v_opp_a,v_customer_a,1,'AUTHORIZED','2026-11-17T00:00:00Z'),
    (v_tenant,v_store_a,v_opp_a,v_customer_a,2,'AUTHORIZED','2026-11-17T00:01:00Z'),
    (v_tenant,v_store_b,v_opp_b,v_customer_b,1,'AUTHORIZED','2026-11-17T00:00:00Z'),
    (v_tenant,v_store_b,v_opp_b,v_customer_b,2,'AUTHORIZED','2026-11-17T00:01:00Z');

  -- Resolve the four intervention IDs explicitly; INSERT RETURNING row order is not a contract.
  SELECT id INTO v_intervention_a1 FROM henvalt.shopify_recovery_intervention_v2 WHERE opportunity_id=v_opp_a AND step_number=1;
  SELECT id INTO v_intervention_a2 FROM henvalt.shopify_recovery_intervention_v2 WHERE opportunity_id=v_opp_a AND step_number=2;
  SELECT id INTO v_intervention_b1 FROM henvalt.shopify_recovery_intervention_v2 WHERE opportunity_id=v_opp_b AND step_number=1;
  SELECT id INTO v_intervention_b2 FROM henvalt.shopify_recovery_intervention_v2 WHERE opportunity_id=v_opp_b AND step_number=2;

  INSERT INTO henvalt.shopify_recovery_send_attempt_v2(
    tenant_id,shopify_connection_id,customer_identity_id,intervention_id,
    provider_account_key,idempotency_key,status,submitted_at
  ) VALUES
    (v_tenant,v_store_a,v_customer_a,v_intervention_a1,v_provider_key,'attrib-a-step-1','AUTHORIZED','2026-11-17T00:00:00Z'),
    (v_tenant,v_store_a,v_customer_a,v_intervention_a2,v_provider_key,'attrib-a-step-2','AUTHORIZED','2026-11-17T00:01:00Z'),
    (v_tenant,v_store_b,v_customer_b,v_intervention_b1,v_provider_key,'attrib-b-step-1','AUTHORIZED','2026-11-17T00:00:00Z'),
    (v_tenant,v_store_b,v_customer_b,v_intervention_b2,v_provider_key,'attrib-b-step-2','AUTHORIZED','2026-11-17T00:01:00Z');

  SELECT id INTO v_attempt_a1 FROM henvalt.shopify_recovery_send_attempt_v2 WHERE shopify_connection_id=v_store_a AND idempotency_key='attrib-a-step-1';
  SELECT id INTO v_attempt_a2 FROM henvalt.shopify_recovery_send_attempt_v2 WHERE shopify_connection_id=v_store_a AND idempotency_key='attrib-a-step-2';
  SELECT id INTO v_attempt_b1 FROM henvalt.shopify_recovery_send_attempt_v2 WHERE shopify_connection_id=v_store_b AND idempotency_key='attrib-b-step-1';
  SELECT id INTO v_attempt_b2 FROM henvalt.shopify_recovery_send_attempt_v2 WHERE shopify_connection_id=v_store_b AND idempotency_key='attrib-b-step-2';

  -- Transition through the real AUTHORIZED -> SUBMITTED lifecycle. Keep policy
  -- disabled during these updates so neither row can prematurely win attribution.
  UPDATE henvalt.shopify_recovery_send_attempt_v2
     SET status='SUBMITTED',updated_at=pg_catalog.now()
   WHERE idempotency_key IN ('attrib-a-step-1','attrib-a-step-2','attrib-b-step-1','attrib-b-step-2')
     AND tenant_id=v_tenant;

  IF (SELECT count(*) FROM henvalt.shopify_delivery_cost_reservations_v2
      WHERE send_attempt_id IN (v_attempt_a1,v_attempt_a2,v_attempt_b1,v_attempt_b2)
        AND status='SETTLED')<>4 THEN
    RAISE EXCEPTION 'Authorized-to-submitted lifecycle did not settle all four synthetic cost reservations';
  END IF;

  -- Policy is enabled only after both eligible touches exist, so a trigger cannot
  -- prematurely attribute the first inserted attempt before the second is visible.
  v_eval := henvalt.set_shopify_recovery_attribution_policy_v2(
    v_store_a,true,24,'FIRST_ELIGIBLE_TOUCH','SHOPIFY_TOTAL_PRICE',false
  );
  IF v_eval->>'accepted'<>'true' THEN RAISE EXCEPTION 'Store A first-touch policy rejected: %',v_eval; END IF;
  v_eval := henvalt.set_shopify_recovery_attribution_policy_v2(
    v_store_b,true,24,'LAST_ELIGIBLE_TOUCH','SHOPIFY_TOTAL_PRICE',false
  );
  IF v_eval->>'accepted'<>'true' THEN RAISE EXCEPTION 'Store B last-touch policy rejected: %',v_eval; END IF;

  v_eval := henvalt.evaluate_shopify_recovery_attribution_v2(v_order_a);
  IF v_eval->>'accepted'<>'true' THEN RAISE EXCEPTION 'Store A first-touch attribution failed: %',v_eval; END IF;
  v_eval := henvalt.evaluate_shopify_recovery_attribution_v2(v_order_b);
  IF v_eval->>'accepted'<>'true' THEN RAISE EXCEPTION 'Store B last-touch attribution failed: %',v_eval; END IF;

  IF NOT EXISTS (
    SELECT 1 FROM henvalt.shopify_recovery_attributions_v2
    WHERE order_identity_id=v_order_a AND shopify_connection_id=v_store_a
      AND send_attempt_id=v_attempt_a1 AND touch_model='FIRST_ELIGIBLE_TOUCH'
  ) THEN RAISE EXCEPTION 'FIRST_ELIGIBLE_TOUCH did not choose the earliest valid send'; END IF;

  IF NOT EXISTS (
    SELECT 1 FROM henvalt.shopify_recovery_attributions_v2
    WHERE order_identity_id=v_order_b AND shopify_connection_id=v_store_b
      AND send_attempt_id=v_attempt_b2 AND touch_model='LAST_ELIGIBLE_TOUCH'
  ) THEN RAISE EXCEPTION 'LAST_ELIGIBLE_TOUCH did not choose the latest valid send'; END IF;

  -- The active synthetic billing account creates one non-charging fee measurement
  -- for the USD attribution; the GBP order remains unmeasured due currency mismatch.
  IF NOT EXISTS (
    SELECT 1 FROM henvalt.shopify_recovery_fee_measurements_v2 f
    JOIN henvalt.shopify_recovery_attributions_v2 a
      ON a.id=f.attribution_id AND a.tenant_id=f.tenant_id
     AND a.shopify_connection_id=f.shopify_connection_id
    WHERE a.order_identity_id=(SELECT id FROM henvalt.shopify_order_identity_v2
      WHERE shopify_connection_id=v_store_a AND shopify_order_id='889001')
      AND f.recovered_amount=125.50 AND f.henvalt_percentage=5
      AND f.fee_amount=6.2750 AND f.status='PENDING'
      AND f.paddle_transaction_reference IS NULL
  ) THEN RAISE EXCEPTION 'Confirmed Store A attribution did not create exactly the expected pending fee measurement'; END IF;

  IF EXISTS (
    SELECT 1 FROM henvalt.shopify_recovery_fee_measurements_v2 f
    JOIN henvalt.shopify_recovery_attributions_v2 a
      ON a.id=f.attribution_id AND a.tenant_id=f.tenant_id
     AND a.shopify_connection_id=f.shopify_connection_id
    WHERE a.order_identity_id=v_order_b
  ) THEN RAISE EXCEPTION 'Currency-mismatched Store B attribution incorrectly created a fee measurement'; END IF;

  -- First partial refund reduces a pending fee measurement. Once marked paid,
  -- a later refund must preserve the original billed snapshot and create credit.
  v_body := '{"id":335,"order_id":889001,"created_at":"2026-11-17T00:04:00Z","transactions":[{"id":3,"kind":"refund","status":"success","amount":"25.00","currency":"USD"}]}';
  v_hmac := encode(extensions.hmac(convert_to(v_body,'UTF8'),convert_to('synthetic-test-secret-never-used-in-production','UTF8'),'sha256'),'base64');
  SELECT * INTO v_receipt FROM henvalt.accept_shopify_webhook_v2(
    repeat('b',64),v_hmac,encode(convert_to(v_body,'UTF8'),'base64'),
    'store-a.myshopify.com','refunds/create','attribution-refund-a-1','attribution-refund-a-1-event'
  );
  IF v_receipt.accepted IS DISTINCT FROM true THEN RAISE EXCEPTION 'First attribution refund receipt rejected'; END IF;
  v_projection := henvalt.project_verified_shopify_refund_v2(
    repeat('b',64),'attribution-refund-a-1',encode(convert_to(v_body,'UTF8'),'base64')
  );
  IF v_projection->>'status'<>'PROCESSED' THEN RAISE EXCEPTION 'First attribution refund did not project: %',v_projection; END IF;

  IF NOT EXISTS (
    SELECT 1 FROM henvalt.shopify_recovery_fee_measurements_v2 f
    JOIN henvalt.shopify_recovery_attributions_v2 a ON a.id=f.attribution_id
    WHERE a.order_identity_id=(SELECT id FROM henvalt.shopify_order_identity_v2
      WHERE shopify_connection_id=v_store_a AND shopify_order_id='889001')
      AND f.status='PENDING' AND f.recovered_amount=100.50 AND f.fee_amount=5.0250
      AND f.adjusted_recovered_amount=100.50 AND f.adjusted_fee_amount=5.0250
      AND f.credit_amount=0 AND f.reconciliation_status='CURRENT'
  ) THEN RAISE EXCEPTION 'Pending fee measurement did not reconcile the first partial refund'; END IF;

  UPDATE henvalt.shopify_recovery_fee_measurements_v2 f
     SET status='PAID',paddle_transaction_reference='synthetic-paid-reference'
   WHERE f.attribution_id IN (
     SELECT id FROM henvalt.shopify_recovery_attributions_v2
     WHERE order_identity_id=(SELECT id FROM henvalt.shopify_order_identity_v2
       WHERE shopify_connection_id=v_store_a AND shopify_order_id='889001')
   );

  v_body := '{"id":336,"order_id":889001,"created_at":"2026-11-17T00:05:00Z","transactions":[{"id":4,"kind":"refund","status":"success","amount":"25.00","currency":"USD"}]}';
  v_hmac := encode(extensions.hmac(convert_to(v_body,'UTF8'),convert_to('synthetic-test-secret-never-used-in-production','UTF8'),'sha256'),'base64');
  SELECT * INTO v_receipt FROM henvalt.accept_shopify_webhook_v2(
    repeat('b',64),v_hmac,encode(convert_to(v_body,'UTF8'),'base64'),
    'store-a.myshopify.com','refunds/create','attribution-refund-a-2','attribution-refund-a-2-event'
  );
  IF v_receipt.accepted IS DISTINCT FROM true THEN RAISE EXCEPTION 'Second attribution refund receipt rejected'; END IF;
  v_projection := henvalt.project_verified_shopify_refund_v2(
    repeat('b',64),'attribution-refund-a-2',encode(convert_to(v_body,'UTF8'),'base64')
  );
  IF v_projection->>'status'<>'PROCESSED' THEN RAISE EXCEPTION 'Second attribution refund did not project: %',v_projection; END IF;

  IF NOT EXISTS (
    SELECT 1 FROM henvalt.shopify_recovery_fee_measurements_v2 f
    JOIN henvalt.shopify_recovery_attributions_v2 a ON a.id=f.attribution_id
    WHERE a.order_identity_id=(SELECT id FROM henvalt.shopify_order_identity_v2
      WHERE shopify_connection_id=v_store_a AND shopify_order_id='889001')
      AND f.status='PAID' AND f.recovered_amount=100.50 AND f.fee_amount=5.0250
      AND f.adjusted_recovered_amount=75.50 AND f.adjusted_fee_amount=3.7750
      AND f.credit_amount=1.2500 AND f.reconciliation_status='CREDIT_REQUIRED'
      AND f.paddle_transaction_reference='synthetic-paid-reference'
  ) THEN RAISE EXCEPTION 'Paid fee snapshot was overwritten or refund credit was not calculated'; END IF;

  -- A second paid order with the same exact-store checkout token must not consume
  -- the same recovery opportunity or create a second fee-bearing attribution.
  v_body := '{"shop_id":"1001","id":889003,"checkout_token":"opportunity-shared-token","customer":{"id":12345},"total_price":"125.50","currency":"USD","financial_status":"paid","created_at":"2026-11-17T00:03:00Z"}';
  v_hmac := encode(extensions.hmac(convert_to(v_body,'UTF8'),convert_to('synthetic-test-secret-never-used-in-production','UTF8'),'sha256'),'base64');
  SELECT * INTO v_receipt FROM henvalt.accept_shopify_webhook_v2(
    repeat('b',64),v_hmac,encode(convert_to(v_body,'UTF8'),'base64'),
    'store-a.myshopify.com','orders/create','attribution-order-a-replay','attribution-order-a-replay-event'
  );
  IF v_receipt.accepted IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'Second Store A order receipt rejected: %',row_to_json(v_receipt);
  END IF;
  v_projection := henvalt.project_verified_shopify_order_v2(
    repeat('b',64),'attribution-order-a-replay',encode(convert_to(v_body,'UTF8'),'base64')
  );
  IF v_projection->>'accepted'<>'true' THEN
    RAISE EXCEPTION 'Second Store A order projection rejected: %',v_projection;
  END IF;

  SELECT id INTO v_order_a FROM henvalt.shopify_order_identity_v2
  WHERE shopify_connection_id=v_store_a AND shopify_order_id='889003';
  v_eval := henvalt.evaluate_shopify_recovery_attribution_v2(v_order_a);
  IF v_eval->>'accepted'<>'false' OR v_eval->>'code'<>'NO_ELIGIBLE_RECOVERY_TOUCH' THEN
    RAISE EXCEPTION 'Consumed recovery opportunity was not excluded from second order: %',v_eval;
  END IF;
  IF EXISTS (
    SELECT 1 FROM henvalt.shopify_recovery_attributions_v2
    WHERE order_identity_id=v_order_a
  ) THEN RAISE EXCEPTION 'Second order incorrectly created another attribution'; END IF;
END;
$checkout_attribution_touch_v2$;

ROLLBACK;

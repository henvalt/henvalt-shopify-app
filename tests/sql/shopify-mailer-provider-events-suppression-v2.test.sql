-- MailerSend V2 provider event and exact-store suppression integration tests.
\set ON_ERROR_STOP on
INSERT INTO vault.secrets(name,secret) VALUES
 ('test-mailersend-webhook-secret','synthetic-mailersend-webhook-secret'),
 ('test-recipient-fingerprint-key','synthetic-recipient-fingerprint-key-at-least-32-chars');

DO $mailer_v2$
DECLARE
  v_tenant uuid:='00000000-0000-4000-8000-000000000001';
  v_store_a uuid;
  v_store_b uuid;
  v_customer_a uuid;
  v_customer_b uuid;
  v_opportunity_b uuid;
  v_intervention uuid;
  v_attempt uuid;
  v_intervention_late uuid;
  v_attempt_late uuid;
  v_intervention_sent uuid;
  v_attempt_sent uuid;
  v_intervention_suppression uuid;
  v_attempt_suppression uuid;
  v_sender_profile uuid;
  v_suppression_body text:='{"type":"activity.unsubscribed","created_at":"2026-11-17T04:45:00Z","data":{"id":"provider-event-unmatched-unsubscribe-004","domain_id":"domain-123","message_id":"provider-message-unmatched-unsubscribe-004","email_id":"provider-email-unmatched-unsubscribe-004","type":"unsubscribed","recipient":"shared@example.invalid","meta":[]}}';
  v_sent_body text:='{"type":"activity.sent","created_at":"2026-11-17T04:40:00Z","data":{"id":"provider-event-sent-003","domain_id":"domain-123","message_id":"provider-message-sent-003","email_id":"provider-email-sent-003","type":"sent","recipient":"shared@example.invalid","meta":[]}}';
  v_reconcile jsonb;
  v_late_body text:='{"type":"activity.delivered","created_at":"2026-11-17T04:35:00Z","data":{"id":"provider-event-late-002","domain_id":"domain-123","message_id":"provider-message-late-002","email_id":"provider-email-late-002","type":"delivered","recipient":"shared@example.invalid","meta":[]}}';
  v_provider_key text:=repeat('p',32);
  v_secret text:='synthetic-mailersend-webhook-secret';
  v_test_body text:='{"type":"webhook.test","message":"This is a ping test message","created_at":"2026-03-27T07:24:20.577080Z"}';
  v_body text:='{"type":"activity.unsubscribed","created_at":"2026-11-17T04:30:00Z","data":{"id":"provider-event-001","domain_id":"domain-123","message_id":"provider-message-001","email_id":"provider-email-001","type":"unsubscribed","recipient":"shared@example.invalid","meta":{"unsubscribe_reason":"NO_LONGER_WANT"}}}';
  v_changed_body text:='{"type":"activity.unsubscribed","created_at":"2026-11-17T04:30:00Z","data":{"id":"provider-event-001","domain_id":"domain-123","message_id":"provider-message-001","email_id":"provider-email-001","type":"unsubscribed","recipient":"changed@example.invalid","meta":{"unsubscribe_reason":"NO_LONGER_WANT"}}}';
  v_signature text;
  v_result jsonb;
BEGIN
  PERFORM pg_catalog.set_config('request.jwt.claim.role','service_role',true);
  SELECT id INTO v_store_a FROM henvalt.shopify_connections WHERE shop_domain='store-a.myshopify.com';
  SELECT id INTO v_store_b FROM henvalt.shopify_connections WHERE shop_domain='store-b.myshopify.com';
  SELECT id INTO v_customer_a FROM henvalt.shopify_customer_identity_v2 WHERE shopify_connection_id=v_store_a AND external_customer_reference='12345';
  SELECT id INTO v_customer_b FROM henvalt.shopify_customer_identity_v2 WHERE shopify_connection_id=v_store_b AND external_customer_reference='12345';
  SELECT id INTO v_opportunity_b FROM henvalt.shopify_recovery_opportunity_v2
   WHERE shopify_connection_id=v_store_b AND status='CONTACT_RESOLUTION_PENDING'
   ORDER BY created_at DESC LIMIT 1;
  IF v_store_a IS NULL OR v_store_b IS NULL OR v_customer_a IS NULL OR v_customer_b IS NULL OR v_opportunity_b IS NULL THEN
    RAISE EXCEPTION 'MailerSend suppression prerequisites missing';
  END IF;

  INSERT INTO henvalt.billing_accounts(tenant_id,provider,plan_key,recurring_amount,henvalt_percentage,usage_cap_amount,currency,status,test_mode,monthly_email_limit)
  VALUES(v_tenant,'SHOPIFY','STARTER',0,5,10,'USD','ACTIVE',false,10)
  ON CONFLICT(tenant_id) DO UPDATE SET status='ACTIVE',test_mode=false,henvalt_percentage=5,usage_cap_amount=10,currency='USD',monthly_email_limit=10;

  INSERT INTO henvalt.shopify_mailer_provider_registry_v2(
    tenant_id,provider_account_key,mailersend_domain_id,webhook_secret_ref,recipient_fingerprint_secret_ref,
    email_unit_cost_amount,email_unit_cost_currency,status
  ) VALUES(v_tenant,v_provider_key,'domain-123','test-mailersend-webhook-secret','test-recipient-fingerprint-key',0.01,'USD','PENDING');

  -- MailerSend URL validation uses its documented fixed test signing secret.
  v_signature:=encode(extensions.hmac(convert_to(v_test_body,'UTF8'),
    convert_to('test_Am3L1GuOIc4blLUuHqAPxxwkZaJyEk8','UTF8'),'sha256'),'hex');
  v_result:=henvalt.ingest_mailersend_webhook_v2(
    v_provider_key,v_signature,encode(convert_to(v_test_body,'UTF8'),'base64')
  );
  IF v_result->>'accepted'<>'true' OR v_result->>'status'<>'WEBHOOK_TEST_VERIFIED'
     OR v_result->>'event_persisted'<>'false' THEN
    RAISE EXCEPTION 'MailerSend URL-validation test was not safely accepted: %',v_result;
  END IF;

  UPDATE henvalt.shopify_mailer_provider_registry_v2 SET status='ACTIVE' WHERE provider_account_key=v_provider_key;

  INSERT INTO henvalt.shopify_recovery_intervention_v2(
    tenant_id,shopify_connection_id,opportunity_id,customer_identity_id,step_number,status,scheduled_at
  ) VALUES(v_tenant,v_store_b,v_opportunity_b,v_customer_b,1,'SUBMITTED',now())
  RETURNING id INTO v_intervention;

  INSERT INTO henvalt.shopify_recovery_send_attempt_v2(
    tenant_id,shopify_connection_id,customer_identity_id,intervention_id,
    provider_account_key,idempotency_key,provider_message_id,status,submitted_at
  ) VALUES(v_tenant,v_store_b,v_customer_b,v_intervention,v_provider_key,
    'store-b-send-001',NULL,'AUTHORIZED',NULL)
  RETURNING id INTO v_attempt;
  UPDATE henvalt.shopify_recovery_send_attempt_v2 SET status='SUBMITTED',provider_message_id='provider-message-001',submitted_at=now() WHERE id=v_attempt;

  v_signature:=encode(extensions.hmac(convert_to(v_body,'UTF8'),convert_to(v_secret,'UTF8'),'sha256'),'hex');
  v_result:=henvalt.ingest_mailersend_webhook_v2(
    v_provider_key,v_signature,encode(convert_to(v_body,'UTF8'),'base64')
  );
  IF v_result->>'accepted'<>'true' OR v_result->>'suppression_applied'<>'true' THEN
    RAISE EXCEPTION 'Unsubscribe provider event not processed: %',v_result;
  END IF;
  IF NOT EXISTS(
    SELECT 1 FROM henvalt.shopify_delivery_suppressions_v2
    WHERE tenant_id=v_tenant AND shopify_connection_id=v_store_b
      AND customer_identity_id=v_customer_b AND suppression_type='UNSUBSCRIBED'
      AND source_send_attempt_id=v_attempt AND octet_length(recipient_fingerprint)=32
  ) THEN RAISE EXCEPTION 'Store B unsubscribe suppression missing'; END IF;
  IF EXISTS(
    SELECT 1 FROM henvalt.shopify_delivery_suppressions_v2
    WHERE shopify_connection_id=v_store_a AND customer_identity_id=v_customer_a
  ) THEN RAISE EXCEPTION 'Store B unsubscribe leaked into Store A'; END IF;

  v_result:=henvalt.ingest_mailersend_webhook_v2(
    v_provider_key,v_signature,encode(convert_to(v_body,'UTF8'),'base64')
  );
  IF v_result->>'status'<>'DUPLICATE' THEN RAISE EXCEPTION 'Provider event replay not idempotent: %',v_result; END IF;

  v_signature:=encode(extensions.hmac(convert_to(v_changed_body,'UTF8'),convert_to(v_secret,'UTF8'),'sha256'),'hex');
  v_result:=henvalt.ingest_mailersend_webhook_v2(
    v_provider_key,v_signature,encode(convert_to(v_changed_body,'UTF8'),'base64')
  );
  IF v_result->>'accepted'<>'false' OR v_result->>'code'<>'EVENT_ID_BODY_MISMATCH' THEN
    RAISE EXCEPTION 'Provider event ID reuse with changed body not rejected: %',v_result;
  END IF;

  -- A provider event may arrive before the sender persists its provider message ID.
  v_signature:=encode(extensions.hmac(convert_to(v_late_body,'UTF8'),convert_to(v_secret,'UTF8'),'sha256'),'hex');
  v_result:=henvalt.ingest_mailersend_webhook_v2(
    v_provider_key,v_signature,encode(convert_to(v_late_body,'UTF8'),'base64')
  );
  IF v_result->>'accepted'<>'true' OR v_result->>'status'<>'UNMATCHED' THEN
    RAISE EXCEPTION 'Uncorrelated provider event was not retained as UNMATCHED: %',v_result;
  END IF;

  INSERT INTO henvalt.shopify_recovery_intervention_v2(
    tenant_id,shopify_connection_id,opportunity_id,customer_identity_id,step_number,status,scheduled_at
   ) VALUES(v_tenant,v_store_b,v_opportunity_b,v_customer_b,2,'AUTHORIZED',now())
  RETURNING id INTO v_intervention_late;
  INSERT INTO henvalt.shopify_recovery_send_attempt_v2(
    tenant_id,shopify_connection_id,customer_identity_id,intervention_id,
    provider_account_key,idempotency_key,provider_message_id,status,submitted_at
  ) VALUES(v_tenant,v_store_b,v_customer_b,v_intervention_late,v_provider_key,
    'store-b-send-late-002',NULL,'AUTHORIZED',NULL)
  RETURNING id INTO v_attempt_late;
  v_result:=henvalt.record_shopify_delivery_submission_v2(
    v_attempt_late,'AMBIGUOUS','provider-message-late-002'
  );
  IF v_result->>'recorded'<>'true' OR v_result->>'provider_message_id_retained'<>'true'
    OR v_result->>'provider_cost_state'<>'RESERVED' THEN
    RAISE EXCEPTION 'Checkout ambiguous outcome did not retain provider identity and reserved cost: %',v_result;
  END IF;

  -- Reconcile the signed event that arrived before the provider message ID was saved.
  v_reconcile:=henvalt.reconcile_unmatched_shopify_checkout_provider_events_v2(10);
  IF v_reconcile->>'accepted'<>'true' OR (v_reconcile->>'reconciled')::integer<>1
    OR v_reconcile->>'automatic_resend_performed'<>'false'
    OR v_reconcile->>'ambiguous_cost_reservation_released'<>'false' THEN
    RAISE EXCEPTION 'Unmatched provider event was not safely reconciled: %',v_reconcile;
  END IF;
  v_reconcile:=henvalt.reconcile_unmatched_shopify_checkout_provider_events_v2(10);
  IF v_reconcile->>'accepted'<>'true' OR (v_reconcile->>'reconciled')::integer<>0 THEN
    RAISE EXCEPTION 'Duplicate reconciliation was not an idempotent no-op: %',v_reconcile;
  END IF;
  IF NOT EXISTS(
    SELECT 1 FROM henvalt.shopify_mailer_provider_events_v2
    WHERE provider_account_key=v_provider_key AND provider_event_id='provider-event-late-002'
      AND processing_status='PROCESSED' AND send_attempt_id=v_attempt_late
  ) OR NOT EXISTS(
    SELECT 1 FROM henvalt.shopify_recovery_send_attempt_v2
    WHERE id=v_attempt_late AND status='DELIVERED' AND delivered_at IS NOT NULL
  ) OR NOT EXISTS(
    SELECT 1 FROM henvalt.shopify_recovery_intervention_v2
    WHERE id=v_intervention_late AND status='DELIVERED'
  ) OR NOT EXISTS(
    SELECT 1 FROM henvalt.shopify_delivery_cost_reservations_v2
    WHERE send_attempt_id=v_attempt_late AND status='SETTLED'
  ) THEN RAISE EXCEPTION 'Late provider event did not reconcile the ambiguous send and settle its cost'; END IF;

  -- A signed activity.sent event that arrives after the ambiguous ID is stored settles it.
  INSERT INTO henvalt.shopify_recovery_intervention_v2(
    tenant_id,shopify_connection_id,opportunity_id,customer_identity_id,step_number,status,scheduled_at
  ) VALUES(v_tenant,v_store_b,v_opportunity_b,v_customer_b,3,'AUTHORIZED',now())
  RETURNING id INTO v_intervention_sent;
  INSERT INTO henvalt.shopify_recovery_send_attempt_v2(
    tenant_id,shopify_connection_id,customer_identity_id,intervention_id,
    provider_account_key,idempotency_key,provider_message_id,status,submitted_at
  ) VALUES(v_tenant,v_store_b,v_customer_b,v_intervention_sent,v_provider_key,
    'store-b-send-sent-003',NULL,'AUTHORIZED',NULL)
  RETURNING id INTO v_attempt_sent;
  v_result:=henvalt.record_shopify_delivery_submission_v2(
    v_attempt_sent,'AMBIGUOUS','provider-message-sent-003'
  );
  IF v_result->>'recorded'<>'true' THEN
    RAISE EXCEPTION 'Second ambiguous checkout attempt could not retain provider ID: %',v_result;
  END IF;
  v_signature:=encode(extensions.hmac(convert_to(v_sent_body,'UTF8'),convert_to(v_secret,'UTF8'),'sha256'),'hex');
  v_result:=henvalt.ingest_mailersend_webhook_v2(
    v_provider_key,v_signature,encode(convert_to(v_sent_body,'UTF8'),'base64')
  );
  IF v_result->>'accepted'<>'true' OR v_result->>'status'<>'PROCESSED'
    OR NOT EXISTS(
      SELECT 1 FROM henvalt.shopify_recovery_send_attempt_v2
      WHERE id=v_attempt_sent AND status='SUBMITTED'
    ) OR NOT EXISTS(
      SELECT 1 FROM henvalt.shopify_delivery_cost_reservations_v2
      WHERE send_attempt_id=v_attempt_sent AND status='SETTLED'
    ) THEN
    RAISE EXCEPTION 'Signed activity.sent event did not settle ambiguous checkout attempt: %',v_result;
  END IF;

  -- A signed delivery event without the provider's actual timestamp must not
  -- manufacture delivery evidence from database processing time.
  v_body:='{"type":"activity.delivered","data":{"id":"provider-event-missing-time-005","domain_id":"domain-123","message_id":"provider-message-sent-003","email_id":"provider-email-missing-time-005","type":"delivered","recipient":"shared@example.invalid","meta":[]}}';
  v_signature:=encode(extensions.hmac(convert_to(v_body,'UTF8'),convert_to(v_secret,'UTF8'),'sha256'),'hex');
  v_provider_result:=henvalt.ingest_mailersend_webhook_v2(
    v_provider_key,v_signature,encode(convert_to(v_body,'UTF8'),'base64')
  );
  IF v_provider_result->>'accepted'<>'true' OR v_provider_result->>'status'<>'PROCESSED'
    OR NOT EXISTS(
      SELECT 1 FROM henvalt.shopify_recovery_send_attempt_v2
      WHERE id=v_attempt_sent AND status='DELIVERED' AND delivered_at IS NULL
    ) THEN
    RAISE EXCEPTION 'Missing provider timestamp incorrectly created delivery confirmation: %',v_result;
  END IF;

  -- Late unsubscribe uses the original permit fingerprint, not the webhook's recipient string.
  INSERT INTO henvalt.shopify_sender_profiles_v2(
    tenant_id,shopify_connection_id,provider_account_key,from_email,from_name,status,verified_at
  ) VALUES(v_tenant,v_store_b,v_provider_key,'recovery@store-b.example.invalid','Store B','ACTIVE',now())
  RETURNING id INTO v_sender_profile;

  v_signature:=encode(extensions.hmac(convert_to(v_suppression_body,'UTF8'),convert_to(v_secret,'UTF8'),'sha256'),'hex');
  v_result:=henvalt.ingest_mailersend_webhook_v2(
    v_provider_key,v_signature,encode(convert_to(v_suppression_body,'UTF8'),'base64')
  );
  IF v_result->>'accepted'<>'true' OR v_result->>'status'<>'UNMATCHED' THEN
    RAISE EXCEPTION 'Late unsubscribe was not retained as UNMATCHED: %',v_result;
  END IF;

  INSERT INTO henvalt.shopify_recovery_intervention_v2(
    tenant_id,shopify_connection_id,opportunity_id,customer_identity_id,step_number,status,scheduled_at
  ) VALUES(v_tenant,v_store_b,v_opportunity_b,v_customer_b,4,'AUTHORIZED',now())
  RETURNING id INTO v_intervention_suppression;
  INSERT INTO henvalt.shopify_recovery_send_attempt_v2(
    tenant_id,shopify_connection_id,customer_identity_id,intervention_id,
    provider_account_key,idempotency_key,provider_message_id,status,submitted_at
  ) VALUES(v_tenant,v_store_b,v_customer_b,v_intervention_suppression,v_provider_key,
    'store-b-send-unsubscribe-004',NULL,'AUTHORIZED',NULL)
  RETURNING id INTO v_attempt_suppression;
  v_result:=henvalt.record_shopify_delivery_submission_v2(
    v_attempt_suppression,'AMBIGUOUS','provider-message-unmatched-unsubscribe-004'
  );
  IF v_result->>'recorded'<>'true' THEN
    RAISE EXCEPTION 'Late unsubscribe attempt did not retain provider identity: %',v_result;
  END IF;

  INSERT INTO henvalt.shopify_delivery_permits_v2(
    tenant_id,shopify_connection_id,intervention_id,customer_identity_id,
    provider_account_key,sender_profile_id,permit_token_sha256,recipient_fingerprint,
    expires_at,consumed_at,send_attempt_id
  ) VALUES(v_tenant,v_store_b,v_intervention_suppression,v_customer_b,v_provider_key,
    v_sender_profile,encode(extensions.digest(convert_to(gen_random_uuid()::text,'UTF8'),'sha256'),'hex'),
    decode(repeat('ab',32),'hex'),now()+interval '1 hour',now(),v_attempt_suppression);

  v_reconcile:=henvalt.reconcile_unmatched_shopify_checkout_provider_events_v2(10);
  IF v_reconcile->>'accepted'<>'true' OR (v_reconcile->>'reconciled')::integer<>1 THEN
    RAISE EXCEPTION 'Late unsubscribe was not correlated through the original permit: %',v_reconcile;
  END IF;
  IF NOT EXISTS(
    SELECT 1 FROM henvalt.shopify_delivery_suppressions_v2
    WHERE tenant_id=v_tenant AND shopify_connection_id=v_store_b
      AND customer_identity_id=v_customer_b
      AND suppression_type='UNSUBSCRIBED'
      AND source_send_attempt_id=v_attempt_suppression
      AND source_provider_event_id=(
        SELECT id FROM henvalt.shopify_mailer_provider_events_v2
        WHERE provider_account_key=v_provider_key
          AND provider_event_id='provider-event-unmatched-unsubscribe-004'
      )
      AND recipient_fingerprint=decode(repeat('ab',32),'hex')
  ) OR NOT EXISTS(
    SELECT 1 FROM henvalt.shopify_mailer_provider_events_v2
    WHERE provider_account_key=v_provider_key
      AND provider_event_id='provider-event-unmatched-unsubscribe-004'
      AND processing_status='PROCESSED'
      AND send_attempt_id=v_attempt_suppression
  ) THEN
    RAISE EXCEPTION 'Late unsubscribe suppression did not use exact original permit fingerprint';
  END IF;

  IF EXISTS(
    SELECT 1 FROM information_schema.columns
    WHERE table_schema='henvalt' AND table_name='shopify_mailer_provider_events_v2'
      AND column_name ILIKE '%recipient%'
  ) THEN RAISE EXCEPTION 'Provider event inbox unexpectedly stores recipient field'; END IF;
  IF has_function_privilege('anon','henvalt.ingest_mailersend_webhook_v2(text,text,text)','EXECUTE')
     OR has_function_privilege('authenticated','henvalt.ingest_mailersend_webhook_v2(text,text,text)','EXECUTE')
     OR NOT has_function_privilege('service_role','henvalt.ingest_mailersend_webhook_v2(text,text,text)','EXECUTE') THEN
    RAISE EXCEPTION 'MailerSend webhook RPC is not service-role-only';
  END IF;
END;
$mailer_v2$;
SELECT 'shopify_mailer_provider_events_suppression_v2_passed' AS result;


-- Merchant-wide provider-cost reservation integration checks (migration 019).
CREATE OR REPLACE FUNCTION pg_temp.make_cost_test_attempt(
  p_tenant uuid,p_connection uuid,p_customer uuid,p_opportunity uuid,
  p_step integer,p_idempotency_key text,p_provider_key text
) RETURNS uuid
LANGUAGE plpgsql
AS $cost_test$
DECLARE v_intervention uuid; v_attempt uuid;
BEGIN
  INSERT INTO henvalt.shopify_recovery_intervention_v2(
    tenant_id,shopify_connection_id,opportunity_id,customer_identity_id,
    step_number,status,scheduled_at
  ) VALUES(p_tenant,p_connection,p_opportunity,p_customer,p_step,'SUBMITTED',now())
  RETURNING id INTO v_intervention;
  INSERT INTO henvalt.shopify_recovery_send_attempt_v2(
    tenant_id,shopify_connection_id,customer_identity_id,intervention_id,
    provider_account_key,idempotency_key,status
  ) VALUES(p_tenant,p_connection,p_customer,v_intervention,p_provider_key,p_idempotency_key,'AUTHORIZED')
  RETURNING id INTO v_attempt;
  RETURN v_attempt;
END;
$cost_test$;

DO $reservation_v2$
DECLARE
  v_tenant uuid:='00000000-0000-4000-8000-000000000001';
  v_store_a uuid; v_store_b uuid; v_customer_a uuid; v_customer_b uuid;
  v_opportunity_a uuid; v_opportunity_b uuid; v_provider_key text;
  v_attempt uuid; v_failed boolean; v_count bigint; v_total numeric(18,6);
BEGIN
  SELECT id INTO v_store_a FROM henvalt.shopify_connections WHERE shop_domain='store-a.myshopify.com';
  SELECT id INTO v_store_b FROM henvalt.shopify_connections WHERE shop_domain='store-b.myshopify.com';
  SELECT id INTO v_customer_a FROM henvalt.shopify_customer_identity_v2
    WHERE shopify_connection_id=v_store_a AND external_customer_reference='12345';
  SELECT id INTO v_customer_b FROM henvalt.shopify_customer_identity_v2
    WHERE shopify_connection_id=v_store_b AND external_customer_reference='12345';
  SELECT id INTO v_opportunity_a FROM henvalt.shopify_recovery_opportunity_v2
    WHERE shopify_connection_id=v_store_a AND customer_identity_id=v_customer_a
    ORDER BY created_at DESC LIMIT 1;
  SELECT id INTO v_opportunity_b FROM henvalt.shopify_recovery_opportunity_v2
    WHERE shopify_connection_id=v_store_b AND customer_identity_id=v_customer_b
    ORDER BY created_at DESC LIMIT 1;
  SELECT provider_account_key INTO v_provider_key FROM henvalt.shopify_mailer_provider_registry_v2
    WHERE tenant_id=v_tenant AND status='ACTIVE' ORDER BY created_at LIMIT 1;

  IF v_store_a IS NULL OR v_store_b IS NULL OR v_customer_a IS NULL OR v_customer_b IS NULL
     OR v_opportunity_a IS NULL OR v_opportunity_b IS NULL OR v_provider_key IS NULL THEN
    RAISE EXCEPTION 'Cost reservation integration prerequisites missing';
  END IF;

  SELECT count(*),coalesce(sum(amount),0) INTO v_count,v_total
  FROM henvalt.shopify_delivery_cost_reservations_v2
  WHERE tenant_id=v_tenant AND status IN ('RESERVED','SETTLED');
  IF v_count<>4 OR v_total<>0.04 OR EXISTS(
    SELECT 1 FROM henvalt.shopify_delivery_cost_reservations_v2
    WHERE tenant_id=v_tenant AND shopify_connection_id<>v_store_b
  ) THEN
    RAISE EXCEPTION 'Expected four settled Store B reservations before cross-store cap test: count %, total %',v_count,v_total;
  END IF;

  -- The two Store B sends already consume the merchant-wide cap for Store A.
  UPDATE henvalt.billing_accounts SET usage_cap_amount=0.04 WHERE tenant_id=v_tenant;
  v_failed:=false;
  BEGIN
    PERFORM pg_temp.make_cost_test_attempt(v_tenant,v_store_a,v_customer_a,v_opportunity_a,1,'cost-cap-cross-store-a',v_provider_key);
  EXCEPTION WHEN raise_exception THEN v_failed:=true;
  END;
  IF NOT v_failed OR EXISTS(
    SELECT 1 FROM henvalt.shopify_recovery_send_attempt_v2
    WHERE shopify_connection_id=v_store_a AND idempotency_key='cost-cap-cross-store-a'
  ) THEN RAISE EXCEPTION 'Cross-store monetary cap did not reject Store A attempt'; END IF;
  UPDATE henvalt.billing_accounts SET usage_cap_amount=10 WHERE tenant_id=v_tenant;

  UPDATE henvalt.shopify_mailer_provider_registry_v2
    SET email_unit_cost_amount=NULL,email_unit_cost_currency=NULL WHERE provider_account_key=v_provider_key;
  v_failed:=false;
  BEGIN
    PERFORM pg_temp.make_cost_test_attempt(v_tenant,v_store_a,v_customer_a,v_opportunity_a,1,'cost-missing-unit-a',v_provider_key);
  EXCEPTION WHEN raise_exception THEN v_failed:=true;
  END;
  IF NOT v_failed THEN RAISE EXCEPTION 'Missing provider unit cost was unexpectedly accepted'; END IF;

  UPDATE henvalt.shopify_mailer_provider_registry_v2
    SET email_unit_cost_amount=0.01,email_unit_cost_currency='EUR' WHERE provider_account_key=v_provider_key;
  v_failed:=false;
  BEGIN
    PERFORM pg_temp.make_cost_test_attempt(v_tenant,v_store_a,v_customer_a,v_opportunity_a,1,'cost-currency-mismatch-a',v_provider_key);
  EXCEPTION WHEN raise_exception THEN v_failed:=true;
  END;
  IF NOT v_failed THEN RAISE EXCEPTION 'Provider currency mismatch was unexpectedly accepted'; END IF;
  UPDATE henvalt.shopify_mailer_provider_registry_v2
    SET email_unit_cost_amount=0.01,email_unit_cost_currency='USD' WHERE provider_account_key=v_provider_key;

  UPDATE henvalt.billing_accounts SET monthly_email_limit=2 WHERE tenant_id=v_tenant;
  v_failed:=false;
  BEGIN
    PERFORM pg_temp.make_cost_test_attempt(v_tenant,v_store_a,v_customer_a,v_opportunity_a,1,'cost-monthly-limit-a',v_provider_key);
  EXCEPTION WHEN raise_exception THEN v_failed:=true;
  END;
  IF NOT v_failed THEN RAISE EXCEPTION 'Merchant monthly email limit was unexpectedly exceeded'; END IF;
  UPDATE henvalt.billing_accounts SET monthly_email_limit=10 WHERE tenant_id=v_tenant;

  v_attempt:=pg_temp.make_cost_test_attempt(v_tenant,v_store_a,v_customer_a,v_opportunity_a,1,'cost-failed-a',v_provider_key);
  UPDATE henvalt.shopify_recovery_send_attempt_v2 SET status='FAILED' WHERE id=v_attempt;
  IF NOT EXISTS(SELECT 1 FROM henvalt.shopify_delivery_cost_reservations_v2 WHERE send_attempt_id=v_attempt AND status='RELEASED') THEN
    RAISE EXCEPTION 'FAILED send did not release its cost reservation';
  END IF;

  v_attempt:=pg_temp.make_cost_test_attempt(v_tenant,v_store_a,v_customer_a,v_opportunity_a,2,'cost-ambiguous-a',v_provider_key);
  UPDATE henvalt.shopify_recovery_send_attempt_v2 SET status='AMBIGUOUS' WHERE id=v_attempt;
  IF NOT EXISTS(SELECT 1 FROM henvalt.shopify_delivery_cost_reservations_v2 WHERE send_attempt_id=v_attempt AND status='RESERVED') THEN
    RAISE EXCEPTION 'AMBIGUOUS send did not retain its cost reservation';
  END IF;

  v_attempt:=pg_temp.make_cost_test_attempt(v_tenant,v_store_a,v_customer_a,v_opportunity_a,3,'cost-submitted-a',v_provider_key);
  UPDATE henvalt.shopify_recovery_send_attempt_v2 SET status='SUBMITTED' WHERE id=v_attempt;
  IF NOT EXISTS(SELECT 1 FROM henvalt.shopify_delivery_cost_reservations_v2 WHERE send_attempt_id=v_attempt AND status='SETTLED') THEN
    RAISE EXCEPTION 'SUBMITTED send did not settle its cost reservation';
  END IF;

  SELECT count(*),coalesce(sum(amount),0) INTO v_count,v_total
  FROM henvalt.shopify_delivery_cost_reservations_v2
  WHERE tenant_id=v_tenant AND status IN ('RESERVED','SETTLED');
  IF v_count<>6 OR v_total<>0.06 THEN
    RAISE EXCEPTION 'Merchant-wide reserved/settled ledger mismatch: count %, total %',v_count,v_total;
  END IF;
END;
$reservation_v2$;


-- Stale checkout attempts after a process crash become AMBIGUOUS, never retry or release cost.
DO $checkout_stale_v2$
DECLARE
  v_tenant uuid:='00000000-0000-4000-8000-000000000001';
  v_store uuid;
  v_customer uuid;
  v_opportunity uuid;
  v_provider_key text;
  v_intervention uuid;
  v_attempt uuid;
  v_result jsonb;
BEGIN
  PERFORM pg_catalog.set_config('request.jwt.claim.role','service_role',true);
  SELECT id INTO v_store FROM henvalt.shopify_connections
    WHERE tenant_id=v_tenant AND shop_domain='store-b.myshopify.com';
  SELECT id INTO v_customer FROM henvalt.shopify_customer_identity_v2
    WHERE tenant_id=v_tenant AND shopify_connection_id=v_store AND external_customer_reference='12345';
  SELECT id INTO v_opportunity FROM henvalt.shopify_recovery_opportunity_v2
    WHERE tenant_id=v_tenant AND shopify_connection_id=v_store
    ORDER BY created_at DESC LIMIT 1;
  SELECT provider_account_key INTO v_provider_key FROM henvalt.shopify_mailer_provider_registry_v2
    WHERE tenant_id=v_tenant AND status='ACTIVE' ORDER BY created_at LIMIT 1;
  IF v_store IS NULL OR v_customer IS NULL OR v_opportunity IS NULL OR v_provider_key IS NULL THEN
    RAISE EXCEPTION 'Stale checkout attempt fixture prerequisites missing';
  END IF;

  INSERT INTO henvalt.shopify_recovery_intervention_v2(
    tenant_id,shopify_connection_id,opportunity_id,customer_identity_id,step_number,status,scheduled_at
  ) VALUES(v_tenant,v_store,v_opportunity,v_customer,9,'AUTHORIZED',now())
  RETURNING id INTO v_intervention;
  INSERT INTO henvalt.shopify_recovery_send_attempt_v2(
    tenant_id,shopify_connection_id,customer_identity_id,intervention_id,
    provider_account_key,idempotency_key,status
  ) VALUES(v_tenant,v_store,v_customer,v_intervention,v_provider_key,
    'checkout-stale-'||gen_random_uuid()::text,'AUTHORIZED')
  RETURNING id INTO v_attempt;
  UPDATE henvalt.shopify_recovery_send_attempt_v2
  SET created_at=now()-interval '5 minutes'
  WHERE id=v_attempt;

  v_result:=henvalt.mark_stale_shopify_checkout_send_attempts_ambiguous_v2(
    now()-interval '2 minutes',10
  );
  IF v_result->>'accepted'<>'true' OR (v_result->>'marked_ambiguous')::integer<>1
    OR v_result->>'provider_cost_reservation_released'<>'false'
    OR v_result->>'automatic_retry_performed'<>'false' THEN
    RAISE EXCEPTION 'Stale checkout attempt did not become ambiguous safely: %',v_result;
  END IF;
  IF NOT EXISTS(
    SELECT 1 FROM henvalt.shopify_recovery_send_attempt_v2
    WHERE id=v_attempt AND status='AMBIGUOUS'
  ) OR NOT EXISTS(
    SELECT 1 FROM henvalt.shopify_recovery_intervention_v2
    WHERE id=v_intervention AND status='AMBIGUOUS'
  ) OR NOT EXISTS(
    SELECT 1 FROM henvalt.shopify_delivery_cost_reservations_v2
    WHERE send_attempt_id=v_attempt AND status='RESERVED'
  ) THEN
    RAISE EXCEPTION 'Stale checkout reconciliation lost attempt, intervention or reserved-cost state';
  END IF;

  v_result:=henvalt.mark_stale_shopify_checkout_send_attempts_ambiguous_v2(
    now()-interval '2 minutes',10
  );
  IF v_result->>'accepted'<>'true' OR (v_result->>'marked_ambiguous')::integer<>0 THEN
    RAISE EXCEPTION 'Stale checkout reconciliation did not become idempotent: %',v_result;
  END IF;
END;
$checkout_stale_v2$;

-- Explicit-policy exact-store recovered revenue and fee measurement (migration 023).
DO $attribution_v2$
DECLARE
  v_tenant uuid:='00000000-0000-4000-8000-000000000001';
  v_store_a uuid; v_customer_a uuid; v_opportunity_a uuid; v_provider_key text;
  v_intervention uuid; v_attempt uuid; v_order_id uuid; v_attribution_id uuid;
  v_ordered_at timestamptz; v_body text; v_hmac text; v_refund_body text;
  v_result record; v_projection jsonb; v_policy_result jsonb; v_provider_result jsonb;
  v_signature text; v_delivery_at timestamptz;
  v_secret text:='synthetic-mailersend-webhook-secret';
  v_net numeric(18,4); v_fee numeric(18,4); v_status text; v_fee_status text;
BEGIN
  SELECT id INTO v_store_a FROM henvalt.shopify_connections WHERE shop_domain='store-a.myshopify.com';
  SELECT id INTO v_customer_a FROM henvalt.shopify_customer_identity_v2
    WHERE shopify_connection_id=v_store_a AND external_customer_reference='12345';
  SELECT provider_account_key INTO v_provider_key FROM henvalt.shopify_mailer_provider_registry_v2
    WHERE tenant_id=v_tenant AND status='ACTIVE' ORDER BY created_at LIMIT 1;
  IF v_store_a IS NULL OR v_customer_a IS NULL OR v_provider_key IS NULL THEN
    RAISE EXCEPTION 'Attribution integration prerequisites missing';
  END IF;

  INSERT INTO henvalt.shopify_checkout_identity_v2(
    tenant_id,shopify_connection_id,shopify_checkout_id,shopify_checkout_token,
    total_value,currency,customer_identity_id,source_delivery_id,checkout_status,
    created_at,updated_at
  )
  SELECT v_tenant,v_store_a,NULL,'attribution-checkout-token',100,'USD',v_customer_a,d.id,
    'OPEN',now()-interval '2 hours',now()-interval '2 hours'
  FROM henvalt.shopify_webhook_deliveries d
  WHERE d.shopify_delivery_id='eligibility-checkout-a'
  ON CONFLICT(shopify_connection_id,shopify_checkout_token) DO NOTHING;

  INSERT INTO henvalt.shopify_checkout_recovery_candidate_v2(
    tenant_id,shopify_connection_id,checkout_identity_id,checkout_token,source_delivery_id,
    last_activity_at,eligible_after,state
  )
  SELECT v_tenant,v_store_a,c.id,'attribution-checkout-token',c.source_delivery_id,
    now()-interval '2 hours',now()-interval '1 minute','READY_FOR_CONTACT_RESOLUTION'
  FROM henvalt.shopify_checkout_identity_v2 c
  WHERE c.shopify_connection_id=v_store_a AND c.shopify_checkout_token='attribution-checkout-token'
  ON CONFLICT(shopify_connection_id,checkout_token) DO NOTHING;

  PERFORM henvalt.promote_shopify_checkout_recovery_candidates_v2(100);
  SELECT o.id INTO v_opportunity_a
  FROM henvalt.shopify_recovery_opportunity_v2 o
  JOIN henvalt.shopify_checkout_identity_v2 c
    ON c.id=o.checkout_identity_id AND c.tenant_id=o.tenant_id
   AND c.shopify_connection_id=o.shopify_connection_id
  WHERE o.shopify_connection_id=v_store_a AND o.customer_identity_id=v_customer_a
    AND c.shopify_checkout_token='attribution-checkout-token'
  ORDER BY o.created_at DESC LIMIT 1;
  IF v_opportunity_a IS NULL THEN RAISE EXCEPTION 'Could not create Store A attribution opportunity'; END IF;

  -- This store requires provider-confirmed delivery, not merely submission.
  v_policy_result:=henvalt.set_shopify_recovery_attribution_policy_v2(
    v_store_a,true,24,'LAST_ELIGIBLE_TOUCH','SHOPIFY_TOTAL_PRICE',true
  );
  IF v_policy_result->>'accepted'<>'true' THEN RAISE EXCEPTION 'Explicit attribution policy rejected: %',v_policy_result; END IF;

  UPDATE henvalt.shopify_checkout_recovery_candidate_v2
     SET state='READY_FOR_CONTACT_RESOLUTION'
   WHERE shopify_connection_id=v_store_a AND tenant_id=v_tenant;
  UPDATE henvalt.shopify_recovery_opportunity_v2
     SET status='CONTACT_RESOLUTION_PENDING'
   WHERE id=v_opportunity_a AND tenant_id=v_tenant AND shopify_connection_id=v_store_a;

  INSERT INTO henvalt.shopify_recovery_intervention_v2(
    tenant_id,shopify_connection_id,opportunity_id,customer_identity_id,
    step_number,status,scheduled_at
  ) VALUES(v_tenant,v_store_a,v_opportunity_a,v_customer_a,4,'SUBMITTED',now())
  RETURNING id INTO v_intervention;

  INSERT INTO henvalt.shopify_recovery_send_attempt_v2(
    tenant_id,shopify_connection_id,customer_identity_id,intervention_id,
    provider_account_key,idempotency_key,status
  ) VALUES(v_tenant,v_store_a,v_customer_a,v_intervention,v_provider_key,'attribution-send-store-a-001','AUTHORIZED')
  RETURNING id INTO v_attempt;
  UPDATE henvalt.shopify_recovery_send_attempt_v2
     SET status='SUBMITTED',provider_message_id='attribution-message-store-a-001',submitted_at=now()
   WHERE id=v_attempt;

  -- Only a signed MailerSend event's provider timestamp may satisfy the
  -- delivery-confirmation attribution policy.
  v_delivery_at:=now()+interval '30 seconds';
  v_body:=jsonb_build_object(
    'type','activity.delivered',
    'created_at',v_delivery_at,
    'data',jsonb_build_object(
      'id','attribution-delivered-event-store-a-001',
      'domain_id','domain-123',
      'message_id','attribution-message-store-a-001',
      'email_id','attribution-email-store-a-001',
      'type','delivered',
      'recipient','shared@example.invalid',
      'meta',jsonb_build_array()
    )
  )::text;
  v_signature:=encode(extensions.hmac(convert_to(v_body,'UTF8'),convert_to(v_secret,'UTF8'),'sha256'),'hex');
  v_result:=henvalt.ingest_mailersend_webhook_v2(
    v_provider_key,v_signature,encode(convert_to(v_body,'UTF8'),'base64')
  );
  IF v_result->>'accepted'<>'true' OR v_result->>'status'<>'PROCESSED'
     OR NOT EXISTS(
       SELECT 1 FROM henvalt.shopify_recovery_send_attempt_v2
       WHERE id=v_attempt AND status='DELIVERED' AND delivered_at=v_delivery_at
     ) THEN
    RAISE EXCEPTION 'Signed provider delivery timestamp did not reconcile the attribution send: %',v_provider_result;
  END IF;

  v_ordered_at:=now()+interval '1 minute';
  v_body:=jsonb_build_object(
    'shop_id','1001','id',987655,'checkout_token','attribution-checkout-token',
    'customer',jsonb_build_object('id',12345),'total_price','100.00',
    'currency','USD','financial_status','paid','created_at',v_ordered_at
  )::text;
  v_hmac:=encode(extensions.hmac(convert_to(v_body,'UTF8'),
    convert_to('synthetic-test-secret-never-used-in-production','UTF8'),'sha256'),'base64');
  SELECT * INTO v_result FROM henvalt.accept_shopify_webhook_v2(
    repeat('b',64),v_hmac,encode(convert_to(v_body,'UTF8'),'base64'),
    'store-a.myshopify.com','orders/create','attribution-order-store-a-001','attribution-order-event-a-001'
  );
  IF v_result.accepted IS DISTINCT FROM true THEN RAISE EXCEPTION 'Attribution order receipt rejected: %',row_to_json(v_result); END IF;
  v_projection:=henvalt.project_verified_shopify_order_v2(
    repeat('b',64),'attribution-order-store-a-001',encode(convert_to(v_body,'UTF8'),'base64')
  );
  IF v_projection->>'accepted'<>'true' THEN RAISE EXCEPTION 'Attribution order not projected: %',v_projection; END IF;

  SELECT o.id,a.id,a.net_recovered_amount,a.status
    INTO v_order_id,v_attribution_id,v_net,v_status
  FROM henvalt.shopify_order_identity_v2 o
  JOIN henvalt.shopify_recovery_attributions_v2 a
    ON a.order_identity_id=o.id AND a.tenant_id=o.tenant_id AND a.shopify_connection_id=o.shopify_connection_id
  WHERE o.shopify_connection_id=v_store_a AND o.shopify_order_id='987655';
  IF v_attribution_id IS NULL OR v_net<>100 OR v_status<>'CONFIRMED'
     OR NOT EXISTS(SELECT 1 FROM henvalt.shopify_recovery_attributions_v2 WHERE id=v_attribution_id AND send_attempt_id=v_attempt) THEN
    RAISE EXCEPTION 'Paid exact-store order did not attribute to the eligible send: net %, status %',v_net,v_status;
  END IF;
  SELECT fee_amount INTO v_fee FROM henvalt.shopify_recovery_fee_measurements_v2 WHERE attribution_id=v_attribution_id;
  IF v_fee<>5 OR NOT EXISTS(
    SELECT 1 FROM henvalt.shopify_recovery_fee_measurements_v2
    WHERE attribution_id=v_attribution_id AND status='PENDING' AND paddle_transaction_reference IS NULL
  ) THEN RAISE EXCEPTION 'Performance fee measurement did not snapshot the configured 5 percent without charging'; END IF;

  v_refund_body:=jsonb_build_object(
    'id',335,'order_id',987655,'created_at',now()+interval '2 minutes',
    'transactions',jsonb_build_array(jsonb_build_object('id',3,'kind','refund','status','success','amount','20.00','currency','USD'))
  )::text;
  v_hmac:=encode(extensions.hmac(convert_to(v_refund_body,'UTF8'),
    convert_to('synthetic-test-secret-never-used-in-production','UTF8'),'sha256'),'base64');
  SELECT * INTO v_result FROM henvalt.accept_shopify_webhook_v2(
    repeat('b',64),v_hmac,encode(convert_to(v_refund_body,'UTF8'),'base64'),
    'store-a.myshopify.com','refunds/create','attribution-refund-store-a-001','attribution-refund-event-a-001'
  );
  IF v_result.accepted IS DISTINCT FROM true THEN RAISE EXCEPTION 'Attribution refund receipt rejected: %',row_to_json(v_result); END IF;
  v_projection:=henvalt.project_verified_shopify_refund_v2(
    repeat('b',64),'attribution-refund-store-a-001',encode(convert_to(v_refund_body,'UTF8'),'base64')
  );
  IF v_projection->>'accepted'<>'true' THEN RAISE EXCEPTION 'Attribution refund not projected: %',v_projection; END IF;
  SELECT net_recovered_amount,status INTO v_net,v_status FROM henvalt.shopify_recovery_attributions_v2 WHERE id=v_attribution_id;
  SELECT fee_amount INTO v_fee FROM henvalt.shopify_recovery_fee_measurements_v2 WHERE attribution_id=v_attribution_id;
  IF v_net<>80 OR v_status<>'CONFIRMED' OR v_fee<>4 THEN
    RAISE EXCEPTION 'Partial refund did not reduce net recovered revenue and fee: net %, status %, fee %',v_net,v_status,v_fee;
  END IF;

  v_refund_body:=jsonb_build_object(
    'id',336,'order_id',987655,'created_at',now()+interval '3 minutes',
    'transactions',jsonb_build_array(jsonb_build_object('id',4,'kind','refund','status','success','amount','80.00','currency','USD'))
  )::text;
  v_hmac:=encode(extensions.hmac(convert_to(v_refund_body,'UTF8'),
    convert_to('synthetic-test-secret-never-used-in-production','UTF8'),'sha256'),'base64');
  SELECT * INTO v_result FROM henvalt.accept_shopify_webhook_v2(
    repeat('b',64),v_hmac,encode(convert_to(v_refund_body,'UTF8'),'base64'),
    'store-a.myshopify.com','refunds/create','attribution-refund-store-a-002','attribution-refund-event-a-002'
  );
  IF v_result.accepted IS DISTINCT FROM true THEN RAISE EXCEPTION 'Full attribution refund receipt rejected: %',row_to_json(v_result); END IF;
  v_projection:=henvalt.project_verified_shopify_refund_v2(
    repeat('b',64),'attribution-refund-store-a-002',encode(convert_to(v_refund_body,'UTF8'),'base64')
  );
  IF v_projection->>'accepted'<>'true' THEN RAISE EXCEPTION 'Full attribution refund not projected: %',v_projection; END IF;
  SELECT net_recovered_amount,status INTO v_net,v_status FROM henvalt.shopify_recovery_attributions_v2 WHERE id=v_attribution_id;
  SELECT fee_amount,status INTO v_fee,v_fee_status FROM henvalt.shopify_recovery_fee_measurements_v2 WHERE attribution_id=v_attribution_id;
  IF v_net<>0 OR v_status<>'REVERSED' OR v_fee_status<>'VOIDED' OR v_fee<>0 THEN
    RAISE EXCEPTION 'Full refund did not reverse attribution and void fee measurement: net %, attribution status %, fee status %, fee %',v_net,v_status,v_fee_status,v_fee;
  END IF;

  IF EXISTS(
    SELECT 1 FROM henvalt.shopify_recovery_attributions_v2 a
    JOIN henvalt.shopify_order_identity_v2 o ON o.id=a.order_identity_id
    WHERE o.shopify_connection_id<>(SELECT id FROM henvalt.shopify_connections WHERE shop_domain='store-a.myshopify.com')
      AND o.checkout_token='attribution-checkout-token'
  ) THEN RAISE EXCEPTION 'Attribution crossed exact-store boundary'; END IF;
END;
$attribution_v2$;

-- Exact-store app/uninstalled processing (migration 020).
DO $uninstall_v2$
DECLARE
  v_tenant uuid:='00000000-0000-4000-8000-000000000001';
  v_store_a uuid; v_store_b uuid; v_customer_a uuid; v_opportunity_a uuid;
  v_intervention uuid; v_sender uuid; v_provider_key text;
  v_route_a text:=repeat('c',63)||'1'; v_route_b text:=repeat('d',63)||'2';
  v_body_a text:='{"shop_id":"1001","id":777001}';
  v_body_b text:='{"shop_id":"2002","id":777002}';
  v_hmac text; v_result record; v_delivery_id uuid;
BEGIN
  SELECT id INTO v_store_a FROM henvalt.shopify_connections WHERE shop_domain='store-a.myshopify.com';
  SELECT id INTO v_store_b FROM henvalt.shopify_connections WHERE shop_domain='store-b.myshopify.com';
  SELECT id INTO v_customer_a FROM henvalt.shopify_customer_identity_v2
    WHERE shopify_connection_id=v_store_a AND external_customer_reference='12345';
  SELECT id INTO v_opportunity_a FROM henvalt.shopify_recovery_opportunity_v2
    WHERE shopify_connection_id=v_store_a AND customer_identity_id=v_customer_a
    ORDER BY created_at DESC LIMIT 1;
  SELECT provider_account_key INTO v_provider_key FROM henvalt.shopify_mailer_provider_registry_v2
    WHERE tenant_id=v_tenant AND status='ACTIVE' ORDER BY created_at LIMIT 1;
  IF v_store_a IS NULL OR v_store_b IS NULL OR v_customer_a IS NULL
     OR v_opportunity_a IS NULL OR v_provider_key IS NULL THEN
    RAISE EXCEPTION 'Uninstall integration prerequisites missing';
  END IF;

  -- Re-enable Store B only as a synthetic isolation control for this final test.
  UPDATE henvalt.shopify_connections SET active=true WHERE id=v_store_b AND tenant_id=v_tenant;
  UPDATE henvalt.pixel_keys SET active=true,revoked_at=NULL
   WHERE tenant_id=v_tenant AND shopify_connection_id IN (v_store_a,v_store_b);

  INSERT INTO henvalt.pixel_keys(tenant_id,key_digest,allowed_origins,active,revoked_at,shopify_connection_id)
  VALUES
    (v_tenant,repeat('c',64),ARRAY['https://store-a.example'],true,NULL,v_store_a),
    (v_tenant,repeat('d',64),ARRAY['https://store-b.example'],true,NULL,v_store_b);

  INSERT INTO henvalt.shopify_webhook_route_tokens(tenant_id,connection_id,app_key,token_hash)
  VALUES
    (v_tenant,v_store_a,'test_app',encode(extensions.digest(convert_to(v_route_a,'UTF8'),'sha256'),'hex')),
    (v_tenant,v_store_b,'test_app',encode(extensions.digest(convert_to(v_route_b,'UTF8'),'sha256'),'hex'));

  UPDATE henvalt.shopify_checkout_recovery_candidate_v2
     SET state='READY_FOR_CONTACT_RESOLUTION'
   WHERE shopify_connection_id=v_store_a AND tenant_id=v_tenant;
  UPDATE henvalt.shopify_recovery_opportunity_v2
     SET status='CONTACT_RESOLUTION_PENDING'
   WHERE id=v_opportunity_a AND tenant_id=v_tenant AND shopify_connection_id=v_store_a;

  INSERT INTO henvalt.shopify_recovery_intervention_v2(
    tenant_id,shopify_connection_id,opportunity_id,customer_identity_id,
    step_number,status,scheduled_at
  ) VALUES(v_tenant,v_store_a,v_opportunity_a,v_customer_a,10,'READY_FOR_AUTHORIZATION',now())
  RETURNING id INTO v_intervention;

  INSERT INTO henvalt.shopify_sender_profiles_v2(
    tenant_id,shopify_connection_id,provider_account_key,from_email,from_name,status,verified_at
  ) VALUES(v_tenant,v_store_a,v_provider_key,'recovery@henvalt.test','HENVALT','ACTIVE',now())
  RETURNING id INTO v_sender;

  INSERT INTO henvalt.shopify_delivery_permits_v2(
    tenant_id,shopify_connection_id,intervention_id,customer_identity_id,
    provider_account_key,sender_profile_id,permit_token_sha256,recipient_fingerprint,expires_at
  ) VALUES(
    v_tenant,v_store_a,v_intervention,v_customer_a,v_provider_key,v_sender,
    encode(extensions.digest(convert_to(repeat('e',64),'UTF8'),'sha256'),'hex'),
    decode(repeat('ab',32),'hex'),now()+interval '3 minutes'
  );

  v_hmac:=encode(extensions.hmac(convert_to(v_body_a,'UTF8'),
    convert_to('synthetic-test-secret-never-used-in-production','UTF8'),'sha256'),'base64');
  SELECT * INTO v_result FROM henvalt.accept_shopify_webhook_v2(
    v_route_a,v_hmac,encode(convert_to(v_body_a,'UTF8'),'base64'),
    'store-a.myshopify.com','app/uninstalled','uninstall-store-a-001','uninstall-event-a-001'
  );
  IF v_result.accepted IS DISTINCT FROM true OR v_result.duplicate IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'Verified Store A uninstall was not accepted: %',row_to_json(v_result);
  END IF;

  SELECT id INTO v_delivery_id FROM henvalt.shopify_webhook_deliveries
   WHERE connection_id=v_store_a AND shopify_delivery_id='uninstall-store-a-001';
  IF NOT EXISTS(
    SELECT 1 FROM henvalt.shopify_webhook_deliveries
    WHERE id=v_delivery_id AND processing_status='PROCESSED'
      AND metadata->>'uninstall_processor'='EXACT_STORE_V2'
  ) THEN RAISE EXCEPTION 'Uninstall receipt was not synchronously marked processed'; END IF;

  IF EXISTS(SELECT 1 FROM henvalt.shopify_connections WHERE id=v_store_a AND active IS TRUE)
     OR NOT EXISTS(SELECT 1 FROM henvalt.shopify_connections WHERE id=v_store_b AND active IS TRUE) THEN
    RAISE EXCEPTION 'Uninstall did not disable only Store A';
  END IF;
  IF EXISTS(
    SELECT 1 FROM henvalt.shopify_webhook_route_tokens
    WHERE connection_id=v_store_a AND token_hash=encode(extensions.digest(convert_to(v_route_a,'UTF8'),'sha256'),'hex') AND revoked_at IS NULL
  ) OR NOT EXISTS(
    SELECT 1 FROM henvalt.shopify_webhook_route_tokens
    WHERE connection_id=v_store_b AND token_hash=encode(extensions.digest(convert_to(v_route_b,'UTF8'),'sha256'),'hex') AND revoked_at IS NULL
  ) THEN RAISE EXCEPTION 'Uninstall route-token revocation crossed store boundary'; END IF;
  IF EXISTS(SELECT 1 FROM henvalt.pixel_keys WHERE shopify_connection_id=v_store_a AND key_digest=repeat('c',64) AND active IS TRUE)
     OR NOT EXISTS(SELECT 1 FROM henvalt.pixel_keys WHERE shopify_connection_id=v_store_b AND key_digest=repeat('d',64) AND active IS TRUE) THEN
    RAISE EXCEPTION 'Uninstall pixel-key revocation crossed store boundary';
  END IF;
  IF NOT EXISTS(SELECT 1 FROM henvalt.shopify_checkout_recovery_candidate_v2 WHERE shopify_connection_id=v_store_a AND state='STORE_INACTIVE')
     OR NOT EXISTS(SELECT 1 FROM henvalt.shopify_recovery_opportunity_v2 WHERE id=v_opportunity_a AND status='CLOSED')
     OR NOT EXISTS(SELECT 1 FROM henvalt.shopify_recovery_intervention_v2 WHERE id=v_intervention AND status='CANCELLED')
     OR EXISTS(SELECT 1 FROM henvalt.shopify_delivery_permits_v2 WHERE shopify_connection_id=v_store_a) THEN
    RAISE EXCEPTION 'Uninstall did not stop pending exact-store recovery and remove permit material';
  END IF;

  -- A revoked Store A route cannot accept another delivery; Store B remains routable.
  v_hmac:=encode(extensions.hmac(convert_to(v_body_a,'UTF8'),
    convert_to('synthetic-test-secret-never-used-in-production','UTF8'),'sha256'),'base64');
  SELECT * INTO v_result FROM henvalt.accept_shopify_webhook_v2(
    v_route_a,v_hmac,encode(convert_to(v_body_a,'UTF8'),'base64'),
    'store-a.myshopify.com','orders/create','uninstall-after-revoke-a','uninstall-after-revoke-event-a'
  );
  IF v_result.accepted IS DISTINCT FROM false OR v_result.rejection_code<>'ROUTE_TOKEN_INVALID' THEN
    RAISE EXCEPTION 'Revoked Store A route token remained usable';
  END IF;

  v_hmac:=encode(extensions.hmac(convert_to(v_body_b,'UTF8'),
    convert_to('synthetic-test-secret-never-used-in-production','UTF8'),'sha256'),'base64');
  SELECT * INTO v_result FROM henvalt.accept_shopify_webhook_v2(
    v_route_b,v_hmac,encode(convert_to(v_body_b,'UTF8'),'base64'),
    'store-b.myshopify.com','orders/create','uninstall-after-revoke-b','uninstall-after-revoke-event-b'
  );
  IF v_result.accepted IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'Store B route was incorrectly disabled by Store A uninstall: %',row_to_json(v_result);
  END IF;
END;
$uninstall_v2$;

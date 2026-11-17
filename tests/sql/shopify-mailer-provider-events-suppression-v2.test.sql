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
  v_late_body text:='{"type":"activity.delivered","created_at":"2026-11-17T04:35:00Z","data":{"id":"provider-event-late-002","domain_id":"domain-123","message_id":"provider-message-late-002","email_id":"provider-email-late-002","type":"delivered","recipient":"shared@example.invalid","meta":[]}}';
  v_provider_key text:=repeat('p',32);
  v_secret text:='synthetic-mailersend-webhook-secret';
  v_test_body text:='{"type":"webhook.test","message":"This is a ping test message","created_at":"2026-03-27T07:24:20.577080Z"}';
  v_body text:='{"type":"activity.unsubscribed","created_at":"2026-11-17T04:30:00Z","data":{"id":"provider-event-001","domain_id":"domain-123","message_id":"provider-message-001","email_id":"provider-email-001","type":"unsubscribed","recipient":"shared@example.invalid","meta":{"unsubscribe_reason":"NO_LONGER_WANT"}}}';
  v_changed_body text:='{"type":"activity.unsubscribed","created_at":"2026-11-17T04:30:00Z","data":{"id":"provider-event-001","domain_id":"domain-123","message_id":"provider-message-001","email_id":"provider-email-001","type":"unsubscribed","recipient":"changed@example.invalid","meta":{"unsubscribe_reason":"NO_LONGER_WANT"}}}';
  v_signature text;
  v_result jsonb;
BEGIN
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

  INSERT INTO henvalt.shopify_mailer_provider_registry_v2(
    tenant_id,provider_account_key,mailersend_domain_id,webhook_secret_ref,recipient_fingerprint_secret_ref,status
  ) VALUES(v_tenant,v_provider_key,'domain-123','test-mailersend-webhook-secret','test-recipient-fingerprint-key','PENDING');

  -- MailerSend URL validation uses its documented fixed test signing secret.
  v_signature:=encode(extensions.hmac(convert_to(v_test_body,'UTF8'),
    convert_to('test_Am3L3GuOIc4blLUuHqAPxxwkZaJyEk5','UTF8'),'sha256'),'hex');
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
    'store-b-send-001','provider-message-001','SUBMITTED',now())
  RETURNING id INTO v_attempt;

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
  ) VALUES(v_tenant,v_store_b,v_opportunity_b,v_customer_b,2,'SUBMITTED',now())
  RETURNING id INTO v_intervention_late;
  INSERT INTO henvalt.shopify_recovery_send_attempt_v2(
    tenant_id,shopify_connection_id,customer_identity_id,intervention_id,
    provider_account_key,idempotency_key,provider_message_id,status,submitted_at
  ) VALUES(v_tenant,v_store_b,v_customer_b,v_intervention_late,v_provider_key,
    'store-b-send-late-002','provider-message-late-002','SUBMITTED',now())
  RETURNING id INTO v_attempt_late;

  -- The exact same signed event can now correlate without creating a duplicate inbox row.
  v_result:=henvalt.ingest_mailersend_webhook_v2(
    v_provider_key,v_signature,encode(convert_to(v_late_body,'UTF8'),'base64')
  );
  IF v_result->>'accepted'<>'true' OR v_result->>'status'<>'PROCESSED' THEN
    RAISE EXCEPTION 'Unmatched provider event did not correlate on retry: %',v_result;
  END IF;
  IF NOT EXISTS(
    SELECT 1 FROM henvalt.shopify_mailer_provider_events_v2
    WHERE provider_account_key=v_provider_key AND provider_event_id='provider-event-late-002'
      AND processing_status='PROCESSED' AND send_attempt_id=v_attempt_late
  ) OR NOT EXISTS(
    SELECT 1 FROM henvalt.shopify_recovery_send_attempt_v2
    WHERE id=v_attempt_late AND status='DELIVERED'
  ) THEN RAISE EXCEPTION 'Late provider event correlation did not update exact send attempt'; END IF;

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

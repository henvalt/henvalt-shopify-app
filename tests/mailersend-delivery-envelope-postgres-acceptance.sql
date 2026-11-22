\set ON_ERROR_STOP on

DO $envelope_acceptance$
DECLARE
  v_tenant uuid := gen_random_uuid();
  v_other_tenant uuid := gen_random_uuid();
  v_config uuid := gen_random_uuid();
  v_delivery uuid := gen_random_uuid();
  v_customer uuid := gen_random_uuid();
  v_checkout uuid := gen_random_uuid();
  v_opportunity uuid := gen_random_uuid();
  v_recovery uuid := gen_random_uuid();
  v_intervention uuid := gen_random_uuid();
  v_message uuid := gen_random_uuid();
  v_reply_token text;
  v_result boolean;
  v_signature regprocedure := 'henvalt.assert_mailersend_delivery_envelope(uuid,uuid,text,text,text,text,text,text,text)'::regprocedure;
BEGIN
  -- This is an isolated disposable database with no provider network. Open
  -- only the SQL interlock needed to construct a claimed fixture row.
  PERFORM henvalt.set_provider_sending_enabled(true, 'isolated disposable PostgreSQL acceptance fixture');

  INSERT INTO henvalt.tenants(id, status) VALUES
    (v_tenant, 'ACTIVE'),
    (v_other_tenant, 'ACTIVE');

  INSERT INTO henvalt.provider_configs(
    id, tenant_id, channel, provider, active, configuration
  ) VALUES (
    v_config, v_tenant, 'EMAIL', 'mailersend', true,
    '{"credential_validated":"true","verified_domain":"example.invalid"}'::jsonb
  );

  INSERT INTO henvalt.sending_identities(
    tenant_id, channel, delivery_mode, provider, sender_reference,
    provider_config_id, active, metadata
  ) VALUES (
    v_tenant, 'EMAIL', 'HENVALT_MANAGED', 'mailersend',
    'recovery@example.invalid', v_config, true,
    '{"from_name":"HENVALT Test","reply_to":"support@example.invalid"}'::jsonb
  );

  INSERT INTO henvalt.customers(id, tenant_id, shopify_customer_id, email, email_consent)
  VALUES (v_customer, v_tenant, 'synthetic-customer', 'customer@example.invalid', true);
  INSERT INTO henvalt.checkouts(id, tenant_id, customer_id, session_reference, created_at, updated_at, metadata)
  VALUES (v_checkout, v_tenant, v_customer, 'synthetic-session', now(), now(),
          '{"shop_domain":"envelope-fixture.myshopify.com"}'::jsonb);
  INSERT INTO henvalt.shopify_connections(id, tenant_id, active, shop_domain)
  VALUES (gen_random_uuid(), v_tenant, true, 'envelope-fixture.myshopify.com');
  INSERT INTO henvalt.opportunities(
    id, tenant_id, customer_id, checkout_id, opportunity_type, status
  ) VALUES (v_opportunity, v_tenant, v_customer, v_checkout, 'ABANDONED_CHECKOUT', 'ELIGIBLE');
  INSERT INTO henvalt.recovery_sequences(id, tenant_id, opportunity_id, status)
  VALUES (v_recovery, v_tenant, v_opportunity, 'SCHEDULED');
  INSERT INTO henvalt.recovery_interventions(id, tenant_id, opportunity_id, sequence_id, status)
  VALUES (v_intervention, v_tenant, v_opportunity, v_recovery, 'SENDING');
  INSERT INTO henvalt.messages(id, tenant_id, intervention_id, recipient, subject, body, metadata)
  VALUES (v_message, v_tenant, v_intervention, 'customer@example.invalid',
          'Synthetic delivery test', 'Hello customer. Unsubscribe: https://unsubscribe.example.invalid/token',
          '{"unsubscribe_url":"https://unsubscribe.example.invalid/token"}'::jsonb);
  INSERT INTO henvalt.delivery_requests(
    id, tenant_id, status, recipient_reference, channel, provider,
    delivery_mode, provider_claimed_at, opportunity_id, recovery_id, intervention_id, message_reference
  ) VALUES (
    v_delivery, v_tenant, 'UNKNOWN', 'customer@example.invalid',
    'EMAIL', 'mailersend', 'HENVALT_MANAGED', now(), v_opportunity, v_recovery, v_intervention, v_message
  );

  SELECT henvalt.assert_mailersend_delivery_envelope(
    v_tenant, v_delivery, 'customer@example.invalid',
    'recovery@example.invalid', 'HENVALT Test', 'support@example.invalid',
    'Synthetic delivery test',
    'Hello customer. Unsubscribe: https://unsubscribe.example.invalid/token',
    'Hello customer. Unsubscribe: https://unsubscribe.example.invalid/token'
  ) INTO v_result;
  IF v_result IS NOT TRUE THEN
    RAISE EXCEPTION 'valid tenant delivery envelope was rejected';
  END IF;

  v_reply_token := encode(
    extensions.hmac(
      convert_to(v_tenant::text || ':' || v_delivery::text, 'UTF8'),
      convert_to('synthetic-reply-routing-secret-0123456789abcdef', 'UTF8'),
      'sha256'
    ),
    'hex'
  );
  INSERT INTO henvalt.customer_conversations(
    tenant_id, delivery_request_id, customer_id, opportunity_id, recovery_id,
    intervention_id, reply_token_hash, status
  ) VALUES (
    v_tenant, v_delivery, v_customer, v_opportunity, v_recovery,
    v_intervention,
    encode(extensions.digest(convert_to(v_reply_token, 'UTF8'), 'sha256'), 'hex'),
    'OPEN'
  );

  IF henvalt.assert_mailersend_delivery_envelope(
    v_tenant, v_delivery, 'customer@example.invalid',
    'recovery@example.invalid', 'HENVALT Test',
    'reply+' || v_reply_token || '@inbound.henvalt.com',
    'Synthetic delivery test',
    'Hello customer. Unsubscribe: https://unsubscribe.example.invalid/token',
    'Hello customer. Unsubscribe: https://unsubscribe.example.invalid/token'
  ) IS NOT TRUE THEN
    RAISE EXCEPTION 'valid HENVALT reply-routing address was rejected';
  END IF;

  IF henvalt.assert_mailersend_delivery_envelope(
    v_tenant, v_delivery, 'customer@example.invalid',
    'recovery@example.invalid', 'HENVALT Test',
    'reply+' || repeat('0', 64) || '@inbound.henvalt.com',
    'Synthetic delivery test',
    'Hello customer. Unsubscribe: https://unsubscribe.example.invalid/token',
    'Hello customer. Unsubscribe: https://unsubscribe.example.invalid/token'
  ) IS TRUE THEN
    RAISE EXCEPTION 'unbound HENVALT reply-routing token was authorized';
  END IF;

  IF henvalt.assert_mailersend_delivery_envelope(
    v_tenant, v_delivery, 'attacker@example.invalid',
    'recovery@example.invalid', 'HENVALT Test', 'support@example.invalid',
    'Synthetic delivery test',
    'Hello customer. Unsubscribe: https://unsubscribe.example.invalid/token',
    'Hello customer. Unsubscribe: https://unsubscribe.example.invalid/token'
  ) IS TRUE THEN
    RAISE EXCEPTION 'mismatched recipient was authorized';
  END IF;

  IF henvalt.assert_mailersend_delivery_envelope(
    v_other_tenant, v_delivery, 'customer@example.invalid',
    'recovery@example.invalid', 'HENVALT Test', 'support@example.invalid',
    'Synthetic delivery test',
    'Hello customer. Unsubscribe: https://unsubscribe.example.invalid/token',
    'Hello customer. Unsubscribe: https://unsubscribe.example.invalid/token'
  ) IS TRUE THEN
    RAISE EXCEPTION 'cross-tenant delivery envelope was authorized';
  END IF;

  IF henvalt.assert_mailersend_delivery_envelope(
    v_tenant, v_delivery, 'customer@example.invalid',
    'attacker@example.invalid', 'HENVALT Test', 'support@example.invalid'
  ,
    'Synthetic delivery test',
    'Hello customer. Unsubscribe: https://unsubscribe.example.invalid/token',
    'Hello customer. Unsubscribe: https://unsubscribe.example.invalid/token') IS TRUE THEN
    RAISE EXCEPTION 'unconfigured sender was authorized';
  END IF;

  IF henvalt.assert_mailersend_delivery_envelope(
    v_tenant, v_delivery, 'customer@example.invalid',
    'recovery@example.invalid', 'Spoofed Sender', 'support@example.invalid',
    'Synthetic delivery test',
    'Hello customer. Unsubscribe: https://unsubscribe.example.invalid/token',
    'Hello customer. Unsubscribe: https://unsubscribe.example.invalid/token'
  ) IS TRUE THEN
    RAISE EXCEPTION 'spoofed sender display name was authorized';
  END IF;

  IF henvalt.assert_mailersend_delivery_envelope(
    v_tenant, v_delivery, 'customer@example.invalid',
    'recovery@example.invalid', 'HENVALT Test', 'attacker@example.invalid',
    'Synthetic delivery test',
    'Hello customer. Unsubscribe: https://unsubscribe.example.invalid/token',
    'Hello customer. Unsubscribe: https://unsubscribe.example.invalid/token'
  ) IS TRUE THEN
    RAISE EXCEPTION 'unconfigured reply-to was authorized';
  END IF;

  IF henvalt.assert_mailersend_delivery_envelope(
    v_tenant, v_delivery, 'customer@example.invalid',
    'recovery@example.invalid', 'HENVALT Test', 'support@example.invalid',
    'Tampered subject',
    'Hello customer. Unsubscribe: https://unsubscribe.example.invalid/token',
    'Hello customer. Unsubscribe: https://unsubscribe.example.invalid/token'
  ) IS TRUE THEN
    RAISE EXCEPTION 'tampered subject was authorized';
  END IF;

  IF henvalt.assert_mailersend_delivery_envelope(
    v_tenant, v_delivery, 'customer@example.invalid',
    'recovery@example.invalid', 'HENVALT Test', 'support@example.invalid',
    'Synthetic delivery test',
    'Injected attacker HTML',
    'Hello customer. Unsubscribe: https://unsubscribe.example.invalid/token'
  ) IS TRUE THEN
    RAISE EXCEPTION 'tampered HTML body was authorized';
  END IF;

  UPDATE henvalt.delivery_requests SET provider_claimed_at = NULL WHERE id = v_delivery;
  IF henvalt.assert_mailersend_delivery_envelope(
    v_tenant, v_delivery, 'customer@example.invalid',
    'recovery@example.invalid', 'HENVALT Test', 'support@example.invalid',
    'Synthetic delivery test',
    'Hello customer. Unsubscribe: https://unsubscribe.example.invalid/token',
    'Hello customer. Unsubscribe: https://unsubscribe.example.invalid/token'
  ) IS TRUE THEN
    RAISE EXCEPTION 'unclaimed delivery request was authorized';
  END IF;

  UPDATE henvalt.delivery_requests SET provider_claimed_at = now() WHERE id = v_delivery;
  UPDATE henvalt.customers SET email_consent = false WHERE id = v_customer;
  IF henvalt.assert_mailersend_delivery_envelope(
    v_tenant, v_delivery, 'customer@example.invalid',
    'recovery@example.invalid', 'HENVALT Test', 'support@example.invalid',
    'Synthetic delivery test',
    'Hello customer. Unsubscribe: https://unsubscribe.example.invalid/token',
    'Hello customer. Unsubscribe: https://unsubscribe.example.invalid/token'
  ) IS TRUE THEN
    RAISE EXCEPTION 'revoked email consent was authorized';
  END IF;
  UPDATE henvalt.customers SET email_consent = true WHERE id = v_customer;
  INSERT INTO henvalt.email_suppressions(tenant_id, customer_id, email_normalized, active)
  VALUES (v_tenant, v_customer, 'customer@example.invalid', true);
  IF henvalt.assert_mailersend_delivery_envelope(
    v_tenant, v_delivery, 'customer@example.invalid',
    'recovery@example.invalid', 'HENVALT Test', 'support@example.invalid',
    'Synthetic delivery test',
    'Hello customer. Unsubscribe: https://unsubscribe.example.invalid/token',
    'Hello customer. Unsubscribe: https://unsubscribe.example.invalid/token'
  ) IS TRUE THEN
    RAISE EXCEPTION 'suppressed recipient was authorized';
  END IF;
  DELETE FROM henvalt.email_suppressions WHERE tenant_id = v_tenant;
  UPDATE henvalt.opportunities SET status = 'SUPPRESSED' WHERE id = v_opportunity;
  IF henvalt.assert_mailersend_delivery_envelope(
    v_tenant, v_delivery, 'customer@example.invalid',
    'recovery@example.invalid', 'HENVALT Test', 'support@example.invalid',
    'Synthetic delivery test',
    'Hello customer. Unsubscribe: https://unsubscribe.example.invalid/token',
    'Hello customer. Unsubscribe: https://unsubscribe.example.invalid/token'
  ) IS TRUE THEN
    RAISE EXCEPTION 'ineligible opportunity was authorized';
  END IF;
  UPDATE henvalt.opportunities SET status = 'ELIGIBLE' WHERE id = v_opportunity;
  UPDATE henvalt.tenants SET status = 'SUSPENDED' WHERE id = v_tenant;
  IF henvalt.assert_mailersend_delivery_envelope(
    v_tenant, v_delivery, 'customer@example.invalid',
    'recovery@example.invalid', 'HENVALT Test', 'support@example.invalid',
    'Synthetic delivery test',
    'Hello customer. Unsubscribe: https://unsubscribe.example.invalid/token',
    'Hello customer. Unsubscribe: https://unsubscribe.example.invalid/token'
  ) IS TRUE THEN
    RAISE EXCEPTION 'suspended tenant delivery was authorized';
  END IF;

  IF has_function_privilege('anon', v_signature, 'EXECUTE')
     OR has_function_privilege('authenticated', v_signature, 'EXECUTE')
     OR NOT has_function_privilege('service_role', v_signature, 'EXECUTE') THEN
    RAISE EXCEPTION 'delivery envelope RPC grants are not restricted to service_role';
  END IF;

  PERFORM henvalt.set_provider_sending_enabled(false, 'close after isolated disposable PostgreSQL acceptance fixture');
END
$envelope_acceptance$;

SELECT 'MAILERSEND_DELIVERY_ENVELOPE_ACCEPTANCE_PASSED' AS result;

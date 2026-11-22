\set ON_ERROR_STOP on

DO $envelope_acceptance$
DECLARE
  v_tenant uuid := gen_random_uuid();
  v_other_tenant uuid := gen_random_uuid();
  v_config uuid := gen_random_uuid();
  v_delivery uuid := gen_random_uuid();
  v_result boolean;
  v_signature regprocedure := 'henvalt.assert_mailersend_delivery_envelope(uuid,uuid,text,text,text,text)'::regprocedure;
BEGIN
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

  INSERT INTO henvalt.delivery_requests(
    id, tenant_id, status, recipient_reference, channel, provider,
    delivery_mode, provider_claimed_at
  ) VALUES (
    v_delivery, v_tenant, 'UNKNOWN', 'customer@example.invalid',
    'EMAIL', 'mailersend', 'HENVALT_MANAGED', now()
  );

  SELECT henvalt.assert_mailersend_delivery_envelope(
    v_tenant, v_delivery, 'customer@example.invalid',
    'recovery@example.invalid', 'HENVALT Test', 'support@example.invalid'
  ) INTO v_result;
  IF v_result IS NOT TRUE THEN
    RAISE EXCEPTION 'valid tenant delivery envelope was rejected';
  END IF;

  IF henvalt.assert_mailersend_delivery_envelope(
    v_tenant, v_delivery, 'attacker@example.invalid',
    'recovery@example.invalid', 'HENVALT Test', 'support@example.invalid'
  ) IS TRUE THEN
    RAISE EXCEPTION 'mismatched recipient was authorized';
  END IF;

  IF henvalt.assert_mailersend_delivery_envelope(
    v_other_tenant, v_delivery, 'customer@example.invalid',
    'recovery@example.invalid', 'HENVALT Test', 'support@example.invalid'
  ) IS TRUE THEN
    RAISE EXCEPTION 'cross-tenant delivery envelope was authorized';
  END IF;

  IF henvalt.assert_mailersend_delivery_envelope(
    v_tenant, v_delivery, 'customer@example.invalid',
    'attacker@example.invalid', 'HENVALT Test', 'support@example.invalid'
  ) IS TRUE THEN
    RAISE EXCEPTION 'unconfigured sender was authorized';
  END IF;

  IF henvalt.assert_mailersend_delivery_envelope(
    v_tenant, v_delivery, 'customer@example.invalid',
    'recovery@example.invalid', 'Spoofed Sender', 'support@example.invalid'
  ) IS TRUE THEN
    RAISE EXCEPTION 'spoofed sender display name was authorized';
  END IF;

  IF henvalt.assert_mailersend_delivery_envelope(
    v_tenant, v_delivery, 'customer@example.invalid',
    'recovery@example.invalid', 'HENVALT Test', 'attacker@example.invalid'
  ) IS TRUE THEN
    RAISE EXCEPTION 'unconfigured reply-to was authorized';
  END IF;

  UPDATE henvalt.delivery_requests SET provider_claimed_at = NULL WHERE id = v_delivery;
  IF henvalt.assert_mailersend_delivery_envelope(
    v_tenant, v_delivery, 'customer@example.invalid',
    'recovery@example.invalid', 'HENVALT Test', 'support@example.invalid'
  ) IS TRUE THEN
    RAISE EXCEPTION 'unclaimed delivery request was authorized';
  END IF;

  UPDATE henvalt.delivery_requests SET provider_claimed_at = now() WHERE id = v_delivery;
  UPDATE henvalt.tenants SET status = 'SUSPENDED' WHERE id = v_tenant;
  IF henvalt.assert_mailersend_delivery_envelope(
    v_tenant, v_delivery, 'customer@example.invalid',
    'recovery@example.invalid', 'HENVALT Test', 'support@example.invalid'
  ) IS TRUE THEN
    RAISE EXCEPTION 'suspended tenant delivery was authorized';
  END IF;

  IF has_function_privilege('anon', v_signature, 'EXECUTE')
     OR has_function_privilege('authenticated', v_signature, 'EXECUTE')
     OR NOT has_function_privilege('service_role', v_signature, 'EXECUTE') THEN
    RAISE EXCEPTION 'delivery envelope RPC grants are not restricted to service_role';
  END IF;
END
$envelope_acceptance$;

SELECT 'MAILERSEND_DELIVERY_ENVELOPE_ACCEPTANCE_PASSED' AS result;

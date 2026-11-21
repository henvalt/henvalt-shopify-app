\set ON_ERROR_STOP on

INSERT INTO henvalt.tenants(id, status)
VALUES ('eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee', 'ACTIVE')
ON CONFLICT (id) DO NOTHING;

INSERT INTO henvalt.shopify_connections(id, tenant_id, active, shop_domain)
VALUES (
  'ffffffff-ffff-4fff-8fff-ffffffffffff',
  'eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee',
  true,
  'single-roundtrip.myshopify.com'
)
ON CONFLICT (id) DO NOTHING;

INSERT INTO vault.decrypted_secrets(id, name, decrypted_secret)
VALUES ('11111111-1111-4111-8111-111111111111', 'henvalt_shopify_app_secret', 'synthetic-app-secret')
ON CONFLICT (id) DO UPDATE SET name = EXCLUDED.name, decrypted_secret = EXCLUDED.decrypted_secret;

DO $single_roundtrip$
DECLARE
  v_first record;
  v_duplicate record;
  v_invalid record;
  v_unknown record;
  v_no_secret record;
  v_count integer;
  v_failed boolean := false;
  v_function text := 'henvalt.receive_shopify_webhook_v1(text,text,text,text,text,jsonb,jsonb)';
BEGIN
  SELECT * INTO v_first
    FROM henvalt.receive_shopify_webhook_v1(
      'single-roundtrip.myshopify.com',
      'orders/paid',
      'single-roundtrip-delivery-001',
      'valid-test-hmac',
      'e30=',
      '{"id":"order-001","test":true}'::jsonb,
      '{"shopify_event_id":"correlation-001","correlation_id":"22222222-2222-4222-8222-222222222222"}'::jsonb
    );

  IF v_first.http_status <> 200
     OR v_first.result_status <> 'accepted'
     OR v_first.tenant_id IS DISTINCT FROM 'eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee'::uuid
     OR v_first.webhook_id IS NULL
     OR v_first.replay_job_id IS NULL
     OR v_first.replay_job_status IS DISTINCT FROM 'QUEUED' THEN
    RAISE EXCEPTION 'SINGLE_ROUNDTRIP_INGRESS_DID_NOT_RETURN_DURABLE_ACCEPTANCE';
  END IF;

  SELECT * INTO v_duplicate
    FROM henvalt.receive_shopify_webhook_v1(
      'single-roundtrip.myshopify.com',
      'orders/paid',
      'single-roundtrip-delivery-001',
      'valid-test-hmac',
      'e30=',
      '{"id":"order-001","test":true}'::jsonb,
      '{"shopify_event_id":"correlation-001","correlation_id":"22222222-2222-4222-8222-222222222222"}'::jsonb
    );

  IF v_duplicate.http_status <> 200
     OR v_duplicate.webhook_id IS DISTINCT FROM v_first.webhook_id
     OR v_duplicate.replay_job_id IS DISTINCT FROM v_first.replay_job_id THEN
    RAISE EXCEPTION 'SINGLE_ROUNDTRIP_DUPLICATE_CREATED_NEW_IDENTITIES';
  END IF;

  SELECT count(*) INTO v_count
    FROM henvalt.webhook_events
   WHERE tenant_id = 'eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee'
     AND source_event_id = 'single-roundtrip-delivery-001';

  IF v_count <> 1 THEN
    RAISE EXCEPTION 'SINGLE_ROUNDTRIP_DUPLICATE_CREATED_MULTIPLE_WEBHOOK_ROWS';
  END IF;

  SELECT * INTO v_invalid
    FROM henvalt.receive_shopify_webhook_v1(
      'missing-shop.myshopify.com',
      'orders/paid',
      'invalid-signature-delivery',
      'invalid-test-hmac',
      'e30=',
      '{"id":"order-invalid","test":true}'::jsonb,
      '{}'::jsonb
    );

  IF v_invalid.http_status <> 401 OR v_invalid.result_status <> 'invalid_hmac' THEN
    RAISE EXCEPTION 'INVALID_HMAC_NOT_REJECTED_BEFORE_TENANT_LOOKUP';
  END IF;

  SELECT count(*) INTO v_count
    FROM henvalt.webhook_events
   WHERE source_event_id = 'invalid-signature-delivery';

  IF v_count <> 0 THEN
    RAISE EXCEPTION 'INVALID_HMAC_CREATED_DURABLE_WEBHOOK_ROW';
  END IF;

  DELETE FROM vault.decrypted_secrets WHERE name = 'henvalt_shopify_app_secret';

  SELECT * INTO v_no_secret
    FROM henvalt.receive_shopify_webhook_v1(
      'single-roundtrip.myshopify.com',
      'orders/paid',
      'missing-secret-delivery',
      'valid-test-hmac',
      'e30=',
      '{"id":"order-secret","test":true}'::jsonb,
      '{}'::jsonb
    );

  IF v_no_secret.http_status <> 503 OR v_no_secret.result_status <> 'hmac_verifier_unavailable' THEN
    RAISE EXCEPTION 'MISSING_HMAC_SECRET_NOT_CLASSIFIED_AS_RETRYABLE';
  END IF;

  INSERT INTO vault.decrypted_secrets(id, name, decrypted_secret)
  VALUES ('11111111-1111-4111-8111-111111111111', 'henvalt_shopify_app_secret', 'synthetic-app-secret')
  ON CONFLICT (id) DO UPDATE SET name = EXCLUDED.name, decrypted_secret = EXCLUDED.decrypted_secret;

  SELECT * INTO v_unknown
    FROM henvalt.receive_shopify_webhook_v1(
      'unknown-shop.myshopify.com',
      'orders/paid',
      'unknown-tenant-delivery',
      'valid-test-hmac',
      'e30=',
      '{"id":"order-unknown","test":true}'::jsonb,
      '{}'::jsonb
    );

  IF v_unknown.http_status <> 404 OR v_unknown.result_status <> 'unknown_tenant' THEN
    RAISE EXCEPTION 'UNKNOWN_TENANT_NOT_CLASSIFIED';
  END IF;

  SELECT * INTO v_invalid
    FROM henvalt.receive_shopify_webhook_v1(
      'single-roundtrip.myshopify.com',
      'orders/paid',
      '',
      'valid-test-hmac',
      'e30=',
      '{"id":"order-missing-delivery","test":true}'::jsonb,
      '{}'::jsonb
    );

  IF v_invalid.http_status <> 422 OR v_invalid.result_status <> 'malformed_event' THEN
    RAISE EXCEPTION 'MISSING_DELIVERY_ID_NOT_REJECTED';
  END IF;

  IF NOT has_function_privilege('service_role', v_function, 'EXECUTE')
     OR has_function_privilege('anon', v_function, 'EXECUTE')
     OR has_function_privilege('authenticated', v_function, 'EXECUTE') THEN
    RAISE EXCEPTION 'SINGLE_ROUNDTRIP_RPC_PRIVILEGES_NOT_RESTRICTED';
  END IF;

  RAISE NOTICE 'SHOPIFY_SINGLE_ROUNDTRIP_INGRESS_ACCEPTANCE_PASSED';
END;
$single_roundtrip$;

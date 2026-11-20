-- Committed disposable fixture for a deterministic competing-order attribution race.
-- A test-only BEFORE INSERT barrier makes both evaluators reach the unique-key
-- insert for the same opportunity before either insert can finish.
\set ON_ERROR_STOP on

CREATE TABLE henvalt.test_attribution_race_fixture_v2 (
  opportunity_id uuid PRIMARY KEY,
  tenant_id uuid NOT NULL,
  shopify_connection_id uuid NOT NULL,
  order_a_id uuid NOT NULL,
  order_b_id uuid NOT NULL
);

DO $setup$
DECLARE
  v_tenant uuid := '00000000-0000-4000-8000-000000000001';
  v_store uuid;
  v_opportunity uuid;
  v_customer uuid;
  v_order_a uuid;
  v_order_b uuid;
  v_attempt uuid;
  v_intervention uuid;
  v_provider text := 'henvalt-attribution-race-provider';
  v_body text;
  v_hmac text;
  v_receipt record;
  v_projection jsonb;
  v_policy jsonb;
BEGIN
  SELECT id INTO v_store FROM henvalt.shopify_connections
   WHERE tenant_id=v_tenant AND shop_domain='store-a.myshopify.com';
  SELECT o.id,o.customer_identity_id INTO v_opportunity,v_customer
    FROM henvalt.shopify_recovery_opportunity_v2 o
    JOIN henvalt.shopify_checkout_recovery_candidate_v2 c
      ON c.id=o.candidate_id AND c.tenant_id=o.tenant_id
     AND c.shopify_connection_id=o.shopify_connection_id
   WHERE o.tenant_id=v_tenant AND o.shopify_connection_id=v_store
     AND c.checkout_token='opportunity-shared-token';
  SELECT id INTO v_order_a FROM henvalt.shopify_order_identity_v2
   WHERE tenant_id=v_tenant AND shopify_connection_id=v_store
     AND shopify_order_id='889001';

  IF v_store IS NULL OR v_opportunity IS NULL OR v_customer IS NULL OR v_order_a IS NULL THEN
    RAISE EXCEPTION 'Attribution race fixture prerequisites missing';
  END IF;
  IF EXISTS (SELECT 1 FROM henvalt.shopify_recovery_attributions_v2
             WHERE opportunity_id=v_opportunity) THEN
    RAISE EXCEPTION 'Attribution race opportunity is already consumed';
  END IF;

  -- Disable attribution while both candidate orders and eligible touches are prepared.
  v_policy := henvalt.set_shopify_recovery_attribution_policy_v2(
    v_store,false,24,'FIRST_ELIGIBLE_TOUCH','SHOPIFY_TOTAL_PRICE',false
  );
  IF v_policy->>'accepted'<>'true' THEN
    RAISE EXCEPTION 'Could not disable attribution during race fixture setup: %',v_policy;
  END IF;

  INSERT INTO henvalt.shopify_mailer_provider_registry_v2(
    tenant_id,provider_account_key,mailersend_domain_id,webhook_secret_ref,
    recipient_fingerprint_secret_ref,status,email_unit_cost_amount,email_unit_cost_currency
  ) VALUES(v_tenant,v_provider,'race-test-domain','vault://race-webhook',
    'vault://race-fingerprint','ACTIVE',0.001,'USD')
  ON CONFLICT(provider_account_key) DO NOTHING;

  INSERT INTO henvalt.billing_accounts(
    tenant_id,status,test_mode,henvalt_percentage,usage_cap_amount,currency,
    monthly_email_limit,activated_at,updated_at
  ) VALUES(v_tenant,'ACTIVE',false,5,100,'USD',100,now(),now())
  ON CONFLICT(tenant_id) DO UPDATE SET status='ACTIVE',test_mode=false,
    henvalt_percentage=5,usage_cap_amount=100,currency='USD',
    monthly_email_limit=100,activated_at=now(),updated_at=now();

  INSERT INTO henvalt.shopify_recovery_intervention_v2(
    tenant_id,shopify_connection_id,opportunity_id,customer_identity_id,
    step_number,status,scheduled_at
  ) VALUES(v_tenant,v_store,v_opportunity,v_customer,91,'AUTHORIZED',now())
  RETURNING id INTO v_intervention;

  INSERT INTO henvalt.shopify_recovery_send_attempt_v2(
    tenant_id,shopify_connection_id,customer_identity_id,intervention_id,
    provider_account_key,idempotency_key,status
  ) VALUES(v_tenant,v_store,v_customer,v_intervention,v_provider,
    'attribution-race-send','AUTHORIZED')
  RETURNING id INTO v_attempt;

  UPDATE henvalt.shopify_recovery_send_attempt_v2
     SET status='SUBMITTED',submitted_at='2026-11-17T00:00:00Z',updated_at=now()
   WHERE id=v_attempt;

  -- Create a second paid order for the exact same store + checkout token.
  -- Policy remains disabled, so neither order can win during setup.
  v_body := '{"shop_id":"1001","id":889004,"checkout_token":"opportunity-shared-token","customer":{"id":12345},"total_price":"125.50","currency":"USD","financial_status":"paid","created_at":"2026-11-17T00:03:30Z"}';
  v_hmac := encode(extensions.hmac(convert_to(v_body,'UTF8'),
    convert_to('synthetic-test-secret-never-used-in-production','UTF8'),'sha256'),'base64');
  SELECT * INTO v_receipt FROM henvalt.accept_shopify_webhook_v2(
    repeat('b',64),v_hmac,encode(convert_to(v_body,'UTF8'),'base64'),
    'store-a.myshopify.com','orders/create','attribution-race-order-b','attribution-race-order-b-event'
  );
  IF v_receipt.accepted IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'Competing order webhook receipt rejected: %',row_to_json(v_receipt);
  END IF;
  v_projection := henvalt.project_verified_shopify_order_v2(
    repeat('b',64),'attribution-race-order-b',encode(convert_to(v_body,'UTF8'),'base64')
  );
  IF v_projection->>'accepted'<>'true' OR v_projection->>'checkout_match_status'<>'MATCHED' THEN
    RAISE EXCEPTION 'Competing order projection failed: %',v_projection;
  END IF;
  SELECT id INTO v_order_b FROM henvalt.shopify_order_identity_v2
   WHERE tenant_id=v_tenant AND shopify_connection_id=v_store
     AND shopify_order_id='889004';
  IF v_order_b IS NULL OR v_order_b=v_order_a THEN
    RAISE EXCEPTION 'Competing order identity was not created';
  END IF;

  INSERT INTO henvalt.test_attribution_race_fixture_v2(
    opportunity_id,tenant_id,shopify_connection_id,order_a_id,order_b_id
  ) VALUES(v_opportunity,v_tenant,v_store,v_order_a,v_order_b);

  v_policy := henvalt.set_shopify_recovery_attribution_policy_v2(
    v_store,true,24,'FIRST_ELIGIBLE_TOUCH','SHOPIFY_TOTAL_PRICE',false
  );
  IF v_policy->>'accepted'<>'true' THEN
    RAISE EXCEPTION 'Could not enable attribution for race test: %',v_policy;
  END IF;
END;
$setup$;

CREATE OR REPLACE FUNCTION henvalt.test_attribution_race_barrier_v2()
RETURNS trigger
LANGUAGE plpgsql
AS $barrier$
BEGIN
  IF EXISTS (
    SELECT 1 FROM henvalt.test_attribution_race_fixture_v2 f
    WHERE f.opportunity_id=NEW.opportunity_id
  ) THEN
    PERFORM pg_catalog.pg_sleep(1.5);
  END IF;
  RETURN NEW;
END;
$barrier$;

CREATE TRIGGER test_attribution_race_barrier_v2
BEFORE INSERT ON henvalt.shopify_recovery_attributions_v2
FOR EACH ROW EXECUTE FUNCTION henvalt.test_attribution_race_barrier_v2();

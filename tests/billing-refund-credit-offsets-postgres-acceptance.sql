\set ON_ERROR_STOP on

BEGIN;

DO $billing_refund_credit_acceptance$
DECLARE
  v_tenant uuid := 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaa0111';
  v_shop_connection uuid := 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbb0111';
  v_credit_1 uuid := 'cccccccc-cccc-4ccc-8ccc-cccccccc0111';
  v_recovery_1 uuid := 'dddddddd-dddd-4ddd-8ddd-dddddddd0111';
  v_recovery_2 uuid := 'dddddddd-dddd-4ddd-8ddd-dddddddd0112';
  v_credit_2 uuid := 'cccccccc-cccc-4ccc-8ccc-cccccccc0112';
  v_recovery_3 uuid := 'dddddddd-dddd-4ddd-8ddd-dddddddd0113';
  v_recovery_4 uuid := 'dddddddd-dddd-4ddd-8ddd-dddddddd0114';
  v_result jsonb;
  v_charge_id uuid;
  v_first_charge uuid;
  v_amount numeric;
  v_status henvalt.billing_status;
  v_offsets numeric;
  v_offset_rows integer;
BEGIN
  IF has_function_privilege('anon','henvalt.control_plane_claim_billing_usage(text)','EXECUTE')
     OR has_function_privilege('authenticated','henvalt.control_plane_claim_billing_usage(text)','EXECUTE') THEN
    RAISE EXCEPTION 'billing usage claim RPC must not be executable by client roles';
  END IF;
  IF NOT has_function_privilege('service_role','henvalt.control_plane_claim_billing_usage(text)','EXECUTE') THEN
    RAISE EXCEPTION 'service_role must retain billing usage claim RPC access';
  END IF;
  IF NOT (SELECT relrowsecurity FROM pg_class WHERE oid='henvalt.billing_measurement_credit_offsets'::regclass) THEN
    RAISE EXCEPTION 'billing credit allocations must have row-level security enabled';
  END IF;

  INSERT INTO henvalt.tenants(id,status,default_currency)
  VALUES (v_tenant,'ACTIVE','USD');

  INSERT INTO henvalt.shopify_connections(id,tenant_id,active,shop_domain)
  VALUES (v_shop_connection,v_tenant,true,'credits.myshopify.com');

  INSERT INTO henvalt.billing_accounts(
    tenant_id,provider,plan_key,recurring_amount,henvalt_percentage,
    usage_cap_amount,currency,usage_line_item_id,status,test_mode,
    activated_at,monthly_email_limit
  ) VALUES (
    v_tenant,'SHOPIFY','PERFORMANCE',0,10,100,'USD','gid://shopify/AppSubscriptionLineItem/credits',
    'ACTIVE',true,now()-interval '1 day',2000
  );

  INSERT INTO henvalt.revenue_ledger(
    id,tenant_id,entry_type,amount,currency,attribution_confidence,billable,billing_status,metadata
  ) VALUES
    ('eeeeeeee-eeee-4eee-8eee-eeeeeeee0111',v_tenant,'ADJUSTMENT',-30,'USD','CONFIRMED',true,'MEASURED','{"source":"refund"}'),
    ('eeeeeeee-eeee-4eee-8eee-eeeeeeee0112',v_tenant,'RECOVERY',100,'USD','CONFIRMED',true,'MEASURED','{}'),
    ('eeeeeeee-eeee-4eee-8eee-eeeeeeee0113',v_tenant,'RECOVERY',20,'USD','CONFIRMED',true,'MEASURED','{}');

  INSERT INTO henvalt.billing_measurements(
    id,tenant_id,billing_period_id,ledger_entry_id,recovered_revenue,
    henvalt_percentage,henvalt_fee,currency,status,created_at
  ) VALUES
    (v_credit_1,v_tenant,gen_random_uuid(),'eeeeeeee-eeee-4eee-8eee-eeeeeeee0111',-30,10,-3,'USD','MEASURED',now()-interval '4 hours'),
    (v_recovery_1,v_tenant,gen_random_uuid(),'eeeeeeee-eeee-4eee-8eee-eeeeeeee0112',100,10,10,'USD','MEASURED',now()-interval '3 hours'),
    (v_recovery_2,v_tenant,gen_random_uuid(),'eeeeeeee-eeee-4eee-8eee-eeeeeeee0113',20,10,2,'USD','MEASURED',now()-interval '2 hours');

  -- A $3 fee credit offsets the first $10 fee; Shopify receives only $7.
  v_result := henvalt.control_plane_claim_billing_usage('credits.myshopify.com');
  IF (v_result->>'available')::boolean IS NOT TRUE
     OR (v_result->>'amount')::numeric <> 7
     OR (v_result->>'refundCreditApplied')::numeric <> 3 THEN
    RAISE EXCEPTION 'expected net $7 charge after $3 refund credit, got %',v_result;
  END IF;
  v_first_charge := (v_result->>'chargeId')::uuid;

  SELECT sum(amount),count(*) INTO v_offsets,v_offset_rows
    FROM henvalt.billing_measurement_credit_offsets
   WHERE tenant_id=v_tenant AND credit_measurement_id=v_credit_1
     AND charge_measurement_id=v_recovery_1;
  IF v_offsets <> 3 OR v_offset_rows <> 1 THEN
    RAISE EXCEPTION 'refund credit allocation was not persisted exactly once';
  END IF;

  -- Retry must preserve the original net charge and must not allocate credits twice.
  UPDATE henvalt.billing_usage_charges
     SET status='FAILED',attempt_count=1,attempted_at=now()-interval '5 minutes'
   WHERE id=v_first_charge;
  v_result := henvalt.control_plane_claim_billing_usage('credits.myshopify.com');
  IF (v_result->>'chargeId')::uuid <> v_first_charge
     OR (v_result->>'amount')::numeric <> 7 THEN
    RAISE EXCEPTION 'retry changed charge identity or net amount: %',v_result;
  END IF;
  SELECT count(*) INTO v_offset_rows
    FROM henvalt.billing_measurement_credit_offsets
   WHERE tenant_id=v_tenant AND credit_measurement_id=v_credit_1;
  IF v_offset_rows <> 1 THEN
    RAISE EXCEPTION 'retry duplicated refund credit allocation';
  END IF;

  -- Once the first recovery is billed, the exhausted credit cannot reduce a second charge.
  UPDATE henvalt.billing_usage_charges SET status='SUBMITTED' WHERE id=v_first_charge;
  UPDATE henvalt.billing_measurements SET status='BILLED' WHERE id=v_recovery_1;
  UPDATE henvalt.revenue_ledger SET billing_status='BILLED'
   WHERE id='eeeeeeee-eeee-4eee-8eee-eeeeeeee0112';
  v_result := henvalt.control_plane_claim_billing_usage('credits.myshopify.com');
  IF (v_result->>'amount')::numeric <> 2 THEN
    RAISE EXCEPTION 'fully consumed credit was reused against a later charge: %',v_result;
  END IF;

  -- A $5 credit fully voids a $3 fee, then offsets $2 of the next $4 fee.
  INSERT INTO henvalt.revenue_ledger(
    id,tenant_id,entry_type,amount,currency,attribution_confidence,billable,billing_status,metadata
  ) VALUES
    ('eeeeeeee-eeee-4eee-8eee-eeeeeeee0114',v_tenant,'ADJUSTMENT',-50,'USD','CONFIRMED',true,'MEASURED','{"source":"refund"}'),
    ('eeeeeeee-eeee-4eee-8eee-eeeeeeee0115',v_tenant,'RECOVERY',30,'USD','CONFIRMED',true,'MEASURED','{}'),
    ('eeeeeeee-eeee-4eee-8eee-eeeeeeee0116',v_tenant,'RECOVERY',40,'USD','CONFIRMED',true,'MEASURED','{}');

  INSERT INTO henvalt.billing_measurements(
    id,tenant_id,billing_period_id,ledger_entry_id,recovered_revenue,
    henvalt_percentage,henvalt_fee,currency,status,created_at
  ) VALUES
    (v_credit_2,v_tenant,gen_random_uuid(),'eeeeeeee-eeee-4eee-8eee-eeeeeeee0114',-50,10,-5,'USD','MEASURED',now()-interval '1 hour'),
    (v_recovery_3,v_tenant,gen_random_uuid(),'eeeeeeee-eeee-4eee-8eee-eeeeeeee0115',30,10,3,'USD','MEASURED',now()-interval '50 minutes'),
    (v_recovery_4,v_tenant,gen_random_uuid(),'eeeeeeee-eeee-4eee-8eee-eeeeeeee0116',40,10,4,'USD','MEASURED',now()-interval '40 minutes');

  v_result := henvalt.control_plane_claim_billing_usage('credits.myshopify.com');
  IF (v_result->>'available')::boolean IS NOT FALSE
     OR v_result->>'reason' <> 'FULLY_OFFSET_BY_REFUND_CREDIT' THEN
    RAISE EXCEPTION 'fully credited charge was not voided: %',v_result;
  END IF;
  SELECT status INTO v_status FROM henvalt.billing_measurements WHERE id=v_recovery_3;
  IF v_status <> 'VOIDED' THEN
    RAISE EXCEPTION 'fully credited measurement was not voided';
  END IF;

  v_result := henvalt.control_plane_claim_billing_usage('credits.myshopify.com');
  IF (v_result->>'available')::boolean IS NOT TRUE
     OR (v_result->>'amount')::numeric <> 2
     OR (v_result->>'refundCreditApplied')::numeric <> 2 THEN
    RAISE EXCEPTION 'remaining $2 credit was not applied to next $4 fee: %',v_result;
  END IF;

  SELECT sum(amount) INTO v_offsets
    FROM henvalt.billing_measurement_credit_offsets
   WHERE tenant_id=v_tenant AND credit_measurement_id=v_credit_2;
  IF v_offsets <> 5 THEN
    RAISE EXCEPTION 'refund credit was not consumed exactly once across two measurements';
  END IF;

  -- Credits arriving after a charge was created do not rewrite that pending charge.
  -- They offset the next new positive measurement instead.
  INSERT INTO henvalt.tenants(id,status,default_currency)
  VALUES ('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaa0112','ACTIVE','USD');
  INSERT INTO henvalt.shopify_connections(id,tenant_id,active,shop_domain)
  VALUES ('bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbb0112','aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaa0112',true,'late-credit.myshopify.com');
  INSERT INTO henvalt.billing_accounts(
    tenant_id,provider,plan_key,recurring_amount,henvalt_percentage,
    usage_cap_amount,currency,usage_line_item_id,status,test_mode,
    activated_at,monthly_email_limit
  ) VALUES (
    'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaa0112','SHOPIFY','PERFORMANCE',0,10,100,'USD',
    'gid://shopify/AppSubscriptionLineItem/late-credit','ACTIVE',true,now()-interval '1 day',2000
  );
  INSERT INTO henvalt.revenue_ledger(
    id,tenant_id,entry_type,amount,currency,attribution_confidence,billable,billing_status,metadata
  ) VALUES
    ('eeeeeeee-eeee-4eee-8eee-eeeeeeee0117','aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaa0112','RECOVERY',100,'USD','CONFIRMED',true,'MEASURED','{}'),
    ('eeeeeeee-eeee-4eee-8eee-eeeeeeee0118','aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaa0112','ADJUSTMENT',-50,'USD','CONFIRMED',true,'MEASURED','{}'),
    ('eeeeeeee-eeee-4eee-8eee-eeeeeeee0119','aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaa0112','RECOVERY',80,'USD','CONFIRMED',true,'MEASURED','{}');
  INSERT INTO henvalt.billing_measurements(
    id,tenant_id,billing_period_id,ledger_entry_id,recovered_revenue,
    henvalt_percentage,henvalt_fee,currency,status,created_at
  ) VALUES (
    'dddddddd-dddd-4ddd-8ddd-dddddddd0115','aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaa0112',gen_random_uuid(),
    'eeeeeeee-eeee-4eee-8eee-eeeeeeee0117',100,10,10,'USD','MEASURED',now()-interval '2 hours'
  );

  v_result := henvalt.control_plane_claim_billing_usage('late-credit.myshopify.com');
  IF (v_result->>'amount')::numeric <> 10 THEN
    RAISE EXCEPTION 'initial pending charge should be the full $10 fee: %',v_result;
  END IF;
  v_first_charge := (v_result->>'chargeId')::uuid;

  INSERT INTO henvalt.billing_measurements(
    id,tenant_id,billing_period_id,ledger_entry_id,recovered_revenue,
    henvalt_percentage,henvalt_fee,currency,status,created_at
  ) VALUES
    ('cccccccc-cccc-4ccc-8ccc-cccccccc0113','aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaa0112',gen_random_uuid(),
     'eeeeeeee-eeee-4eee-8eee-eeeeeeee0118',-50,10,-5,'USD','MEASURED',now()-interval '1 hour'),
    ('dddddddd-dddd-4ddd-8ddd-dddddddd0116','aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaa0112',gen_random_uuid(),
     'eeeeeeee-eeee-4eee-8eee-eeeeeeee0119',80,10,8,'USD','MEASURED',now()-interval '30 minutes');

  UPDATE henvalt.billing_usage_charges
     SET status='FAILED',attempt_count=1,attempted_at=now()-interval '5 minutes'
   WHERE id=v_first_charge;
  v_result := henvalt.control_plane_claim_billing_usage('late-credit.myshopify.com');
  IF (v_result->>'chargeId')::uuid <> v_first_charge
     OR (v_result->>'amount')::numeric <> 10 THEN
    RAISE EXCEPTION 'late refund credit rewrote an already-created pending charge: %',v_result;
  END IF;
  IF EXISTS (
    SELECT 1 FROM henvalt.billing_measurement_credit_offsets
     WHERE tenant_id='aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaa0112'
       AND credit_measurement_id='cccccccc-cccc-4ccc-8ccc-cccccccc0113'
  ) THEN
    RAISE EXCEPTION 'late credit must not be allocated to a pre-existing charge';
  END IF;

  UPDATE henvalt.billing_usage_charges SET status='SUBMITTED' WHERE id=v_first_charge;
  UPDATE henvalt.billing_measurements SET status='BILLED'
   WHERE id='dddddddd-dddd-4ddd-8ddd-dddddddd0115';
  UPDATE henvalt.revenue_ledger SET billing_status='BILLED'
   WHERE id='eeeeeeee-eeee-4eee-8eee-eeeeeeee0117';

  v_result := henvalt.control_plane_claim_billing_usage('late-credit.myshopify.com');
  IF (v_result->>'amount')::numeric <> 3
     OR (v_result->>'refundCreditApplied')::numeric <> 5 THEN
    RAISE EXCEPTION 'late refund credit was not applied to the next charge: %',v_result;
  END IF;

  -- Live-mode subscriptions are blocked by default in this candidate worker.
  INSERT INTO henvalt.tenants(id,status,default_currency)
  VALUES ('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaa0113','ACTIVE','USD');
  INSERT INTO henvalt.shopify_connections(id,tenant_id,active,shop_domain)
  VALUES ('bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbb0113','aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaa0113',true,'live-blocked.myshopify.com');
  INSERT INTO henvalt.billing_accounts(
    tenant_id,provider,plan_key,recurring_amount,henvalt_percentage,
    usage_cap_amount,currency,usage_line_item_id,status,test_mode,
    activated_at,monthly_email_limit
  ) VALUES (
    'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaa0113','SHOPIFY','PERFORMANCE',0,10,100,'USD',
    'gid://shopify/AppSubscriptionLineItem/live-blocked','ACTIVE',false,now()-interval '1 day',2000
  );
  INSERT INTO henvalt.revenue_ledger(
    id,tenant_id,entry_type,amount,currency,attribution_confidence,billable,billing_status,metadata
  ) VALUES (
    'eeeeeeee-eeee-4eee-8eee-eeeeeeee0120','aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaa0113',
    'RECOVERY',100,'USD','CONFIRMED',true,'MEASURED','{}'
  );
  INSERT INTO henvalt.billing_measurements(
    id,tenant_id,billing_period_id,ledger_entry_id,recovered_revenue,
    henvalt_percentage,henvalt_fee,currency,status,created_at
  ) VALUES (
    'dddddddd-dddd-4ddd-8ddd-dddddddd0117','aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaa0113',
    gen_random_uuid(),'eeeeeeee-eeee-4eee-8eee-eeeeeeee0120',100,10,10,'USD','MEASURED',now()
  );

  v_result := henvalt.control_plane_claim_billing_usage('live-blocked.myshopify.com');
  IF (v_result->>'available')::boolean IS TRUE
     OR v_result->>'reason' <> 'TEST_MODE_REQUIRED' THEN
    RAISE EXCEPTION 'live-mode subscription was not blocked by default: %',v_result;
  END IF;
  IF EXISTS (
    SELECT 1 FROM henvalt.billing_usage_charges
     WHERE tenant_id='aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaa0113'
       AND billing_measurement_id='dddddddd-dddd-4ddd-8ddd-dddddddd0117'
  ) THEN
    RAISE EXCEPTION 'live-mode subscription created a usage charge despite the test-mode gate';
  END IF;

END;
$billing_refund_credit_acceptance$;

ROLLBACK;

SELECT 'BILLING_REFUND_CREDIT_OFFSETS_ACCEPTANCE_PASSED' AS result;

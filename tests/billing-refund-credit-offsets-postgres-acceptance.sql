\set ON_ERROR_STOP on

BEGIN;

DO $billing_refund_credit_acceptance$
DECLARE
  v_tenant uuid := 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaa0111';
  v_shop_connection uuid := 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbb0111';
  v_second_shop_connection uuid := 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbb0199';
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
  v_original_key text;
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
    v_tenant,'SHOPIFY','STARTER',0,10,100,'USD','gid://shopify/AppSubscriptionLineItem/credits',
    'ACTIVE',true,now()-interval '1 day',2000
  );

  -- One tenant-level billing account must never be claimed through two shops.
  INSERT INTO henvalt.shopify_connections(id,tenant_id,active,shop_domain)
  VALUES (v_second_shop_connection,v_tenant,true,'credits-secondary.myshopify.com');
  v_result := henvalt.control_plane_claim_billing_usage('credits.myshopify.com');
  IF v_result->>'available' <> 'false'
     OR v_result->>'reason' <> 'SINGLE_ACTIVE_SHOP_REQUIRED' THEN
    RAISE EXCEPTION 'billing claim did not fail closed for multiple active shops: %',v_result;
  END IF;
  UPDATE henvalt.shopify_connections SET active=false WHERE id=v_second_shop_connection;

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
    'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaa0112','SHOPIFY','STARTER',0,10,100,'USD',
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
    'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaa0113','SHOPIFY','STARTER',0,10,100,'USD',
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

  -- Durable reconciliation: exact-match finalization and confirmed no-match retry.
  PERFORM set_config('request.jwt.claim.role','service_role',true);
  INSERT INTO henvalt.tenants(id,status,default_currency) VALUES ('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaa0114','ACTIVE','USD');
  INSERT INTO henvalt.shopify_connections(id,tenant_id,active,shop_domain) VALUES ('bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbb0114','aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaa0114',true,'reconcile-match.myshopify.com');
  INSERT INTO henvalt.billing_accounts(tenant_id,provider,plan_key,recurring_amount,henvalt_percentage,usage_cap_amount,currency,usage_line_item_id,status,test_mode,activated_at,monthly_email_limit)
  VALUES ('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaa0114','SHOPIFY','STARTER',0,10,100,'USD','gid://shopify/AppSubscriptionLineItem/reconcile-match','ACTIVE',true,now()-interval '1 day',2000);
  INSERT INTO henvalt.revenue_ledger(id,tenant_id,entry_type,amount,currency,attribution_confidence,billable,billing_status,metadata)
  VALUES ('eeeeeeee-eeee-4eee-8eee-eeeeeeee0121','aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaa0114','RECOVERY',100,'USD','CONFIRMED',true,'MEASURED','{}');
  INSERT INTO henvalt.billing_measurements(id,tenant_id,billing_period_id,ledger_entry_id,recovered_revenue,henvalt_percentage,henvalt_fee,currency,status,created_at)
  VALUES ('dddddddd-dddd-4ddd-8ddd-dddddddd0118','aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaa0114',gen_random_uuid(),'eeeeeeee-eeee-4eee-8eee-eeeeeeee0121',100,10,10,'USD','MEASURED',now());
  v_result := henvalt.control_plane_claim_billing_usage('reconcile-match.myshopify.com');
  v_charge_id := (v_result->>'chargeId')::uuid;
  UPDATE henvalt.billing_usage_charges SET attempt_count=5,attempted_at=now()-interval '5 minutes' WHERE id=v_charge_id;
  v_result := henvalt.control_plane_mark_billing_reconciliation_required('reconcile-match.myshopify.com',v_charge_id,'SHOPIFY_TRANSPORT_OUTCOME_UNKNOWN');
  IF v_result->>'updated' <> 'true' OR v_result->>'status' <> 'REQUIRED' THEN RAISE EXCEPTION 'durable reconciliation marker failed: %',v_result; END IF;
  v_result := henvalt.control_plane_list_billing_reconciliations('reconcile-match.myshopify.com',50);
  IF (v_result->>'count')::integer <> 1
     OR jsonb_array_length(v_result->'cases') <> 1
     OR v_result->'cases'->0->>'chargeId' <> v_charge_id::text THEN
    RAISE EXCEPTION 'tenant-scoped reconciliation queue did not list the pending case: %',v_result;
  END IF;
  IF v_result::text LIKE '%accessToken%' THEN
    RAISE EXCEPTION 'reconciliation queue leaked credential fields';
  END IF;
  v_result := henvalt.control_plane_get_billing_reconciliation('reconcile-match.myshopify.com',v_charge_id);
  IF v_result->>'available' <> 'true' OR v_result->>'idempotencyKey' IS NULL OR v_result ? 'accessToken' THEN RAISE EXCEPTION 'safe reconciliation envelope invalid: %',v_result; END IF;
  v_result := henvalt.control_plane_get_billing_reconciliation('other-tenant.myshopify.com',v_charge_id);
  IF v_result->>'available' <> 'false' THEN RAISE EXCEPTION 'reconciliation read crossed tenant/shop boundary'; END IF;
  v_result := henvalt.control_plane_resolve_billing_reconciliation('reconcile-match.myshopify.com',v_charge_id,'MISMATCH',NULL,
    jsonb_build_object('lookupComplete',true,'matchingCount','1','reason','provider amount mismatch'),
    'operator-test-0','Provider evidence does not match the charge; stop for further review');
  IF v_result->>'updated' <> 'true' OR v_result->>'status' <> 'MISMATCH_REQUIRES_REVIEW' THEN RAISE EXCEPTION 'mismatch did not remain in manual review: %',v_result; END IF;
  v_result := henvalt.control_plane_claim_billing_usage('reconcile-match.myshopify.com');
  IF v_result->>'available' <> 'false' THEN RAISE EXCEPTION 'scheduler claim retried a mismatch reconciliation case: %',v_result; END IF;
  v_result := henvalt.control_plane_resolve_billing_reconciliation('reconcile-match.myshopify.com',v_charge_id,'MATCHED','gid://shopify/AppUsageRecord/reconcile-match-1',
    jsonb_build_object('lookupComplete',true,'subscriptionFound',true,'lineItemFound',true,'providerUsageRecordId','gid://shopify/AppUsageRecord/reconcile-match-1','matchingCount','1','idempotencyKey',(SELECT idempotency_key FROM henvalt.billing_usage_charges WHERE id=v_charge_id),'lineItemId','gid://shopify/AppSubscriptionLineItem/reconcile-match','amount','10','currency','USD','pagesScanned',1,'accessToken','must-not-persist'),
    'operator-test-1','Verified exact provider idempotency key, amount, currency and line item');
  IF v_result->>'updated' <> 'true' OR v_result->>'status' <> 'SUBMITTED' THEN RAISE EXCEPTION 'matched reconciliation failed: %',v_result; END IF;
  IF NOT EXISTS (SELECT 1 FROM henvalt.billing_usage_charges WHERE id=v_charge_id AND status='SUBMITTED' AND reconciliation_status='MATCHED' AND provider_usage_record_id='gid://shopify/AppUsageRecord/reconcile-match-1') THEN RAISE EXCEPTION 'matched charge was not finalized'; END IF;
  IF EXISTS (SELECT 1 FROM henvalt.billing_usage_charges WHERE id=v_charge_id AND reconciliation_evidence ? 'accessToken') THEN RAISE EXCEPTION 'arbitrary evidence key was persisted'; END IF;
  IF NOT EXISTS (SELECT 1 FROM henvalt.billing_measurements WHERE id='dddddddd-dddd-4ddd-8ddd-dddddddd0118' AND status='BILLED') OR NOT EXISTS (SELECT 1 FROM henvalt.revenue_ledger WHERE id='eeeeeeee-eeee-4eee-8eee-eeeeeeee0121' AND billing_status='BILLED') THEN RAISE EXCEPTION 'matched measurement and ledger were not finalized'; END IF;

  INSERT INTO henvalt.tenants(id,status,default_currency) VALUES ('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaa0115','ACTIVE','USD');
  INSERT INTO henvalt.shopify_connections(id,tenant_id,active,shop_domain) VALUES ('bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbb0115','aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaa0115',true,'reconcile-retry.myshopify.com');
  INSERT INTO henvalt.billing_accounts(tenant_id,provider,plan_key,recurring_amount,henvalt_percentage,usage_cap_amount,currency,usage_line_item_id,status,test_mode,activated_at,monthly_email_limit)
  VALUES ('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaa0115','SHOPIFY','STARTER',0,10,100,'USD','gid://shopify/AppSubscriptionLineItem/reconcile-retry','ACTIVE',true,now()-interval '1 day',2000);
  INSERT INTO henvalt.revenue_ledger(id,tenant_id,entry_type,amount,currency,attribution_confidence,billable,billing_status,metadata)
  VALUES ('eeeeeeee-eeee-4eee-8eee-eeeeeeee0122','aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaa0115','RECOVERY',100,'USD','CONFIRMED',true,'MEASURED','{}');
  INSERT INTO henvalt.billing_measurements(id,tenant_id,billing_period_id,ledger_entry_id,recovered_revenue,henvalt_percentage,henvalt_fee,currency,status,created_at)
  VALUES ('dddddddd-dddd-4ddd-8ddd-dddddddd0119','aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaa0115',gen_random_uuid(),'eeeeeeee-eeee-4eee-8eee-eeeeeeee0122',100,10,10,'USD','MEASURED',now());
  v_result := henvalt.control_plane_claim_billing_usage('reconcile-retry.myshopify.com');
  v_charge_id := (v_result->>'chargeId')::uuid;
  SELECT idempotency_key INTO v_original_key FROM henvalt.billing_usage_charges WHERE id=v_charge_id;
  UPDATE henvalt.billing_usage_charges SET attempt_count=5,attempted_at=now()-interval '5 minutes' WHERE id=v_charge_id;
  PERFORM henvalt.control_plane_mark_billing_reconciliation_required('reconcile-retry.myshopify.com',v_charge_id,'SHOPIFY_RESPONSE_NOT_JSON');
  BEGIN
    PERFORM henvalt.control_plane_resolve_billing_reconciliation('reconcile-retry.myshopify.com',v_charge_id,'NOT_FOUND_CONFIRMED',NULL,
      jsonb_build_object('lookupComplete',false,'subscriptionFound',true,'lineItemFound',true,'matchingCount','0','pagesScanned',1),
      'operator-test-invalid','An incomplete lookup must not authorize retry');
    RAISE EXCEPTION 'incomplete no-match evidence was incorrectly accepted';
  EXCEPTION WHEN invalid_parameter_value THEN
    NULL;
  END;
  IF NOT EXISTS (SELECT 1 FROM henvalt.billing_usage_charges WHERE id=v_charge_id AND status='PENDING' AND attempt_count=5 AND reconciliation_status='REQUIRED') THEN RAISE EXCEPTION 'incomplete lookup changed the charge retry state'; END IF;
  v_result := henvalt.control_plane_resolve_billing_reconciliation('reconcile-retry.myshopify.com',v_charge_id,'NOT_FOUND_CONFIRMED',NULL,
    jsonb_build_object('lookupComplete',true,'subscriptionFound',true,'lineItemFound',true,'matchingCount','0','pagesScanned',3),
    'operator-test-2','Complete paginated lookup found no record for the original key');
  IF v_result->>'updated' <> 'true' OR v_result->>'status' <> 'FAILED_RETRY_ALLOWED' THEN RAISE EXCEPTION 'confirmed no-match did not authorize retry: %',v_result; END IF;
  IF NOT EXISTS (SELECT 1 FROM henvalt.billing_usage_charges WHERE id=v_charge_id AND status='FAILED' AND attempt_count=0 AND reconciliation_status='NOT_FOUND_CONFIRMED') THEN RAISE EXCEPTION 'confirmed no-match retry gate incorrect'; END IF;
  v_result := henvalt.control_plane_claim_billing_usage('reconcile-retry.myshopify.com');
  IF (v_result->>'chargeId')::uuid <> v_charge_id OR v_result->>'idempotencyKey' <> v_original_key OR (v_result->>'attempt')::integer <> 1 THEN RAISE EXCEPTION 'retry did not preserve original charge identity and idempotency key: %',v_result; END IF;
  IF NOT EXISTS (SELECT 1 FROM henvalt.billing_usage_charges WHERE id=v_charge_id AND reconciliation_status='NONE') THEN RAISE EXCEPTION 'retry did not clear resolved reconciliation gate'; END IF;
  -- A Shopify provider usage-record ID may settle only one HENVALT charge.
  UPDATE henvalt.billing_usage_charges SET attempt_count=5,attempted_at=now()-interval '5 minutes' WHERE id=v_charge_id;
  PERFORM henvalt.control_plane_mark_billing_reconciliation_required('reconcile-retry.myshopify.com',v_charge_id,'SHOPIFY_TRANSPORT_OUTCOME_UNKNOWN');
  BEGIN
    PERFORM henvalt.control_plane_resolve_billing_reconciliation('reconcile-retry.myshopify.com',v_charge_id,'MATCHED','gid://shopify/AppUsageRecord/reconcile-match-1',
      jsonb_build_object('lookupComplete',true,'subscriptionFound',true,'lineItemFound',true,'providerUsageRecordId','gid://shopify/AppUsageRecord/reconcile-match-1','matchingCount','1','idempotencyKey',v_original_key,'lineItemId','gid://shopify/AppSubscriptionLineItem/reconcile-retry','amount','10','currency','USD','pagesScanned',1),
      'operator-test-duplicate','Attempt to attach an already settled provider record');
    RAISE EXCEPTION 'duplicate provider usage record was attached to a second charge';
  EXCEPTION WHEN unique_violation THEN
    NULL;
  END;
  IF NOT EXISTS (SELECT 1 FROM henvalt.billing_usage_charges WHERE id=v_charge_id AND status='PENDING' AND reconciliation_status='REQUIRED' AND provider_usage_record_id IS NULL) THEN RAISE EXCEPTION 'duplicate provider record attempt mutated second charge'; END IF;
  IF has_function_privilege('anon','henvalt.control_plane_resolve_billing_reconciliation(text,uuid,text,text,jsonb,text,text)','EXECUTE') OR has_function_privilege('authenticated','henvalt.control_plane_resolve_billing_reconciliation(text,uuid,text,text,jsonb,text,text)','EXECUTE') THEN RAISE EXCEPTION 'client roles can execute reconciliation resolution'; END IF;
  IF has_function_privilege('anon','henvalt.control_plane_list_billing_reconciliations(text,integer)','EXECUTE') OR has_function_privilege('authenticated','henvalt.control_plane_list_billing_reconciliations(text,integer)','EXECUTE') THEN RAISE EXCEPTION 'client roles can list reconciliation cases'; END IF;
  IF has_function_privilege('anon','henvalt.control_plane_mark_billing_reconciliation_required(text,uuid,text)','EXECUTE') OR has_function_privilege('authenticated','henvalt.control_plane_mark_billing_reconciliation_required(text,uuid,text)','EXECUTE') THEN RAISE EXCEPTION 'client roles can execute reconciliation marker'; END IF;
  IF has_function_privilege('anon','henvalt.control_plane_get_billing_reconciliation(text,uuid)','EXECUTE') OR has_function_privilege('authenticated','henvalt.control_plane_get_billing_reconciliation(text,uuid)','EXECUTE') THEN RAISE EXCEPTION 'client roles can read reconciliation envelope'; END IF;
  IF NOT has_function_privilege('service_role','henvalt.control_plane_list_billing_reconciliations(text,integer)','EXECUTE') THEN RAISE EXCEPTION 'service_role cannot list reconciliation cases'; END IF;
  IF NOT has_function_privilege('service_role','henvalt.control_plane_mark_billing_reconciliation_required(text,uuid,text)','EXECUTE') OR NOT has_function_privilege('service_role','henvalt.control_plane_get_billing_reconciliation(text,uuid)','EXECUTE') THEN RAISE EXCEPTION 'service_role cannot access reconciliation marker or read RPC'; END IF;
  IF NOT has_function_privilege('service_role','henvalt.control_plane_resolve_billing_reconciliation(text,uuid,text,text,jsonb,text,text)','EXECUTE') THEN RAISE EXCEPTION 'service_role cannot execute reconciliation resolution'; END IF;

  -- If the first attempt to persist REQUIRED failed, the next scheduled claim
  -- must repair the exhausted pending charge and expose it to the operator queue.
  INSERT INTO henvalt.tenants(id,status,default_currency)
  VALUES ('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaa0116','ACTIVE','USD');
  INSERT INTO henvalt.shopify_connections(id,tenant_id,active,shop_domain)
  VALUES ('bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbb0116','aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaa0116',true,'repair-exhausted.myshopify.com');
  INSERT INTO henvalt.billing_accounts(tenant_id,provider,plan_key,recurring_amount,henvalt_percentage,usage_cap_amount,currency,usage_line_item_id,status,test_mode,activated_at,monthly_email_limit)
  VALUES ('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaa0116','SHOPIFY','STARTER',0,10,100,'USD','gid://shopify/AppSubscriptionLineItem/repair-exhausted','ACTIVE',true,now()-interval '1 day',2000);
  INSERT INTO henvalt.revenue_ledger(id,tenant_id,entry_type,amount,currency,attribution_confidence,billable,billing_status,metadata)
  VALUES ('eeeeeeee-eeee-4eee-8eee-eeeeeeee0123','aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaa0116','RECOVERY',100,'USD','CONFIRMED',true,'MEASURED','{}');
  INSERT INTO henvalt.billing_measurements(id,tenant_id,billing_period_id,ledger_entry_id,recovered_revenue,henvalt_percentage,henvalt_fee,currency,status,created_at)
  VALUES ('dddddddd-dddd-4ddd-8ddd-dddddddd0120','aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaa0116',gen_random_uuid(),'eeeeeeee-eeee-4eee-8eee-eeeeeeee0123',100,10,10,'USD','MEASURED',now());
  v_result := henvalt.control_plane_claim_billing_usage('repair-exhausted.myshopify.com');
  v_charge_id := (v_result->>'chargeId')::uuid;
  UPDATE henvalt.billing_usage_charges
     SET attempt_count=5,attempted_at=now()-interval '5 minutes'
   WHERE id=v_charge_id;
  v_result := henvalt.control_plane_claim_billing_usage('repair-exhausted.myshopify.com');
  IF v_result->>'available' <> 'false'
     OR v_result->>'reason' <> 'NO_PENDING_USAGE_CHARGE' THEN
    RAISE EXCEPTION 'exhausted charge was claimed again instead of repaired: %',v_result;
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM henvalt.billing_usage_charges
     WHERE id=v_charge_id
       AND status='PENDING'
       AND reconciliation_status='REQUIRED'
       AND reconciliation_reason='BILLING_RETRY_BUDGET_EXHAUSTED'
  ) THEN
    RAISE EXCEPTION 'exhausted pending charge was not repaired into reconciliation';
  END IF;
  v_result := henvalt.control_plane_list_billing_reconciliations('repair-exhausted.myshopify.com',50);
  IF (v_result->>'count')::integer <> 1 THEN
    RAISE EXCEPTION 'repaired exhausted charge did not reach operator reconciliation queue';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM henvalt.audit_log
     WHERE tenant_id='aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaa0116'
       AND event_name='BILLING_RECONCILIATION_REQUIRED'
       AND entity_id=v_charge_id
  ) THEN
    RAISE EXCEPTION 'exhausted charge repair was not audited';
  END IF;

  -- A late success is authoritative, but a later timeout/failure must not
  -- downgrade the submitted charge or its billed measurement/ledger.
  INSERT INTO henvalt.tenants(id,status,default_currency)
  VALUES ('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaa0117','ACTIVE','USD');
  INSERT INTO henvalt.shopify_connections(id,tenant_id,active,shop_domain)
  VALUES ('bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbb0117','aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaa0117',true,'late-result.myshopify.com');
  INSERT INTO henvalt.billing_accounts(tenant_id,provider,plan_key,recurring_amount,henvalt_percentage,usage_cap_amount,currency,usage_line_item_id,status,test_mode,activated_at,monthly_email_limit)
  VALUES ('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaa0117','SHOPIFY','STARTER',0,10,100,'USD','gid://shopify/AppSubscriptionLineItem/late-result','ACTIVE',true,now()-interval '1 day',2000);
  INSERT INTO henvalt.revenue_ledger(id,tenant_id,entry_type,amount,currency,attribution_confidence,billable,billing_status,metadata)
  VALUES ('eeeeeeee-eeee-4eee-8eee-eeeeeeee0124','aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaa0117','RECOVERY',100,'USD','CONFIRMED',true,'MEASURED','{}');
  INSERT INTO henvalt.billing_measurements(id,tenant_id,billing_period_id,ledger_entry_id,recovered_revenue,henvalt_percentage,henvalt_fee,currency,status,created_at)
  VALUES ('dddddddd-dddd-4ddd-8ddd-dddddddd0121','aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaa0117',gen_random_uuid(),'eeeeeeee-eeee-4eee-8eee-eeeeeeee0124',100,10,10,'USD','MEASURED',now());
  v_result := henvalt.control_plane_claim_billing_usage('late-result.myshopify.com');
  v_charge_id := (v_result->>'chargeId')::uuid;
  UPDATE henvalt.billing_usage_charges SET attempt_count=5,attempted_at=now()-interval '5 minutes' WHERE id=v_charge_id;
  v_result := henvalt.control_plane_mark_billing_reconciliation_required('late-result.myshopify.com',v_charge_id,'SHOPIFY_TRANSPORT_OUTCOME_UNKNOWN');
  IF v_result->>'updated' <> 'true' THEN RAISE EXCEPTION 'late-result reconciliation marker failed: %',v_result; END IF;

  IF has_function_privilege('anon','henvalt.control_plane_record_billing_usage_result(text,uuid,boolean,text,text,text)','EXECUTE')
     OR has_function_privilege('authenticated','henvalt.control_plane_record_billing_usage_result(text,uuid,boolean,text,text,text)','EXECUTE')
     OR NOT has_function_privilege('service_role','henvalt.control_plane_record_billing_usage_result(text,uuid,boolean,text,text,text)','EXECUTE') THEN
    RAISE EXCEPTION 'billing result RPC ACL is not service-role-only';
  END IF;

  v_result := henvalt.control_plane_record_billing_usage_result(
    'late-result.myshopify.com',v_charge_id,true,
    'gid://shopify/AppUsageRecord/late-result-1',NULL,NULL
  );
  IF v_result->>'updated' <> 'true' OR v_result->>'status' <> 'SUBMITTED' THEN
    RAISE EXCEPTION 'late provider success did not settle the charge: %',v_result;
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM henvalt.billing_usage_charges
     WHERE id=v_charge_id AND status='SUBMITTED'
       AND reconciliation_status='MATCHED'
       AND provider_usage_record_id='gid://shopify/AppUsageRecord/late-result-1'
  ) THEN
    RAISE EXCEPTION 'late success did not resolve the durable ambiguity';
  END IF;

  v_result := henvalt.control_plane_record_billing_usage_result(
    'late-result.myshopify.com',v_charge_id,false,NULL,'SHOPIFY_TIMEOUT','late failure after success'
  );
  IF v_result->>'updated' <> 'false' OR v_result->>'reason' <> 'CHARGE_ALREADY_SUBMITTED' THEN
    RAISE EXCEPTION 'late failure was allowed to downgrade a submitted charge: %',v_result;
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM henvalt.billing_usage_charges
     WHERE id=v_charge_id AND status='SUBMITTED'
       AND provider_usage_record_id='gid://shopify/AppUsageRecord/late-result-1'
  ) OR NOT EXISTS (
    SELECT 1 FROM henvalt.billing_measurements
     WHERE id='dddddddd-dddd-4ddd-8ddd-dddddddd0121' AND status='BILLED'
  ) OR NOT EXISTS (
    SELECT 1 FROM henvalt.revenue_ledger
     WHERE id='eeeeeeee-eeee-4eee-8eee-eeeeeeee0124' AND billing_status='BILLED'
  ) THEN
    RAISE EXCEPTION 'late failure corrupted submitted billing state';
  END IF;

  v_result := henvalt.control_plane_record_billing_usage_result(
    'late-result.myshopify.com',v_charge_id,true,
    'gid://shopify/AppUsageRecord/late-result-1',NULL,NULL
  );
  IF v_result->>'updated' <> 'true' OR v_result->>'idempotent' <> 'true' THEN
    RAISE EXCEPTION 'duplicate success result was not idempotent: %',v_result;
  END IF;
END;
$billing_refund_credit_acceptance$;

ROLLBACK;

SELECT 'BILLING_REFUND_CREDIT_OFFSETS_ACCEPTANCE_PASSED' AS result;

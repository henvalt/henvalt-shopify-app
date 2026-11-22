\set ON_ERROR_STOP on

BEGIN;

CREATE UNIQUE INDEX IF NOT EXISTS billing_measurements_test_ledger_unique
  ON henvalt.billing_measurements(tenant_id,ledger_entry_id)
  WHERE ledger_entry_id IS NOT NULL;

CREATE OR REPLACE FUNCTION henvalt.measure_billing_entry(
  p_ledger_entry_id uuid,
  p_henvalt_percentage numeric
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'henvalt','public','pg_temp'
AS $function$
DECLARE
  v_tenant uuid;
  v_amount numeric(18,2);
  v_currency char(3);
  v_id uuid;
BEGIN
  SELECT tenant_id,amount,currency
    INTO v_tenant,v_amount,v_currency
    FROM henvalt.revenue_ledger
   WHERE id=p_ledger_entry_id AND billable=true
   FOR UPDATE;
  IF v_tenant IS NULL THEN RETURN NULL; END IF;

  INSERT INTO henvalt.billing_measurements(
    tenant_id,billing_period_id,ledger_entry_id,recovered_revenue,
    henvalt_percentage,henvalt_fee,currency,status
  ) VALUES (
    v_tenant,gen_random_uuid(),p_ledger_entry_id,v_amount,
    p_henvalt_percentage,round(v_amount*p_henvalt_percentage/100,4),
    v_currency,'MEASURED'
  )
  ON CONFLICT (tenant_id,ledger_entry_id) WHERE ledger_entry_id IS NOT NULL
  DO NOTHING
  RETURNING id INTO v_id;

  IF v_id IS NULL THEN
    SELECT id INTO v_id FROM henvalt.billing_measurements
     WHERE tenant_id=v_tenant AND ledger_entry_id=p_ledger_entry_id;
  END IF;

  UPDATE henvalt.revenue_ledger
     SET billing_status='MEASURED'
   WHERE id=p_ledger_entry_id AND tenant_id=v_tenant;
  RETURN v_id;
END;
$function$;

DO $shopify_order_edit_acceptance$
DECLARE
  v_tenant uuid := 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaa0313';
  v_order uuid := 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbb0313';
  v_recovery uuid := 'cccccccc-cccc-4ccc-8ccc-cccccccc0313';
  v_refund_event uuid := 'dddddddd-dddd-4ddd-8ddd-dddddddd0313';
  v_edit_1 uuid := 'dddddddd-dddd-4ddd-8ddd-dddddddd0314';
  v_edit_2 uuid := 'dddddddd-dddd-4ddd-8ddd-dddddddd0315';
  v_edit_3 uuid := 'dddddddd-dddd-4ddd-8ddd-dddddddd0316';
  v_order_2 uuid := 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbb0314';
  v_recovery_2 uuid := 'cccccccc-cccc-4ccc-8ccc-cccccccc0314';
  v_edit_4 uuid := 'dddddddd-dddd-4ddd-8ddd-dddddddd0317';
  v_order_3 uuid := 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbb0315';
  v_recovery_3 uuid := 'cccccccc-cccc-4ccc-8ccc-cccccccc0315';
  v_existing_adjustment uuid := 'eeeeeeee-eeee-4eee-8eee-eeeeeeee0318';
  v_backfill_event uuid := 'dddddddd-dddd-4ddd-8ddd-dddddddd0318';
  v_order_4 uuid := 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbb0316';
  v_recovery_4 uuid := 'cccccccc-cccc-4ccc-8ccc-cccccccc0316';
  v_edit_5 uuid := 'dddddddd-dddd-4ddd-8ddd-dddddddd0319';
  v_job uuid := 'eeeeeeee-eeee-4eee-8eee-eeeeeeee0320';
  v_lease uuid := 'eeeeeeee-eeee-4eee-8eee-eeeeeeee0321';
  v_result jsonb;
  v_amount numeric;
  v_total numeric;
  v_count integer;
  v_fee numeric;
BEGIN
  IF has_function_privilege('anon','henvalt.process_shopify_order_edit_adjustment(uuid)','EXECUTE')
     OR has_function_privilege('authenticated','henvalt.process_shopify_order_edit_adjustment(uuid)','EXECUTE') THEN
    RAISE EXCEPTION 'order edit adjustment RPC must not be executable by client roles';
  END IF;
  IF NOT has_function_privilege('service_role','henvalt.process_shopify_order_edit_adjustment(uuid)','EXECUTE') THEN
    RAISE EXCEPTION 'service_role must retain order edit adjustment RPC access';
  END IF;
  IF has_function_privilege('anon','henvalt.process_shopify_order_edit_adjustment_fenced(uuid,text,uuid,uuid)','EXECUTE')
     OR has_function_privilege('authenticated','henvalt.process_shopify_order_edit_adjustment_fenced(uuid,text,uuid,uuid)','EXECUTE') THEN
    RAISE EXCEPTION 'fenced order edit RPC must not be executable by client roles';
  END IF;
  IF NOT has_function_privilege('service_role','henvalt.process_shopify_order_edit_adjustment_fenced(uuid,text,uuid,uuid)','EXECUTE') THEN
    RAISE EXCEPTION 'service_role must retain fenced order edit RPC access';
  END IF;

  INSERT INTO henvalt.tenants(id,status,default_currency) VALUES(v_tenant,'ACTIVE','USD');
  INSERT INTO henvalt.orders(id,tenant_id,shopify_order_id,total_value,currency,metadata)
  VALUES(v_order,v_tenant,'order-edit-100',100,'USD','{}');

  INSERT INTO henvalt.revenue_ledger(
    id,tenant_id,order_id,entry_type,amount,currency,
    attribution_confidence,billable,billing_status,metadata
  ) VALUES(
    v_recovery,v_tenant,v_order,'RECOVERY',100,'USD',
    'CONFIRMED',true,'MEASURED','{}'
  );

  INSERT INTO henvalt.billing_measurements(
    tenant_id,billing_period_id,ledger_entry_id,recovered_revenue,
    henvalt_percentage,henvalt_fee,currency,status
  ) VALUES(
    v_tenant,gen_random_uuid(),v_recovery,100,10,10,'USD','MEASURED'
  );

  -- Simulate a $20 refund already posted before Shopify sends orders/updated.
  INSERT INTO henvalt.canonical_events(
    id,tenant_id,event_type,event_class,source,source_event_id,
    occurred_at,payload,metadata,idempotency_key
  ) VALUES(
    v_refund_event,v_tenant,'refunds/create','ADJUSTMENT','shopify',
    'refund-delivery-0313',now(),'{}','{}','refund-idem-0313'
  );
  PERFORM henvalt.create_revenue_adjustment(
    v_order,20,'USD','SUCCESSFUL_SHOPIFY_REFUND',v_refund_event
  );

  -- current_total_price must win over stale total_price (100) during the
  -- order projection itself, before attribution/ledger posting can read the total.
  INSERT INTO henvalt.canonical_events(
    id,tenant_id,event_type,event_class,source,source_event_id,
    occurred_at,payload,metadata,idempotency_key
  ) VALUES(
    v_edit_1,v_tenant,'orders/updated','ADJUSTMENT','shopify',
    'order-edit-delivery-1',now(),
    '{"id":"order-edit-100","total_price":"100.00","current_total_price":"70.00","currency":"USD","current_total_price_set":{"shop_money":{"amount":"70.00","currency_code":"USD"}}}',
    '{}','order-edit-idem-1'
  );
  PERFORM henvalt.project_order_from_event(v_edit_1);
  SELECT total_value INTO v_total FROM henvalt.orders WHERE id=v_order;
  IF v_total <> 70 THEN
    RAISE EXCEPTION 'order projection did not prefer current_total_price over stale total_price';
  END IF;

  v_result := henvalt.process_shopify_order_edit_adjustment(v_edit_1);
  IF v_result->>'status' <> 'adjusted' OR (v_result->>'amount')::numeric <> 10 THEN
    RAISE EXCEPTION 'expected incremental 10 order-edit adjustment after existing refund, got %',v_result;
  END IF;
  SELECT total_value INTO v_total FROM henvalt.orders WHERE id=v_order;
  IF v_total <> 70 THEN RAISE EXCEPTION 'current_total_price did not override stale total_price'; END IF;

  SELECT count(*) INTO v_count FROM henvalt.revenue_ledger
   WHERE tenant_id=v_tenant AND order_id=v_order AND entry_type='ADJUSTMENT';
  IF v_count <> 2 THEN RAISE EXCEPTION 'expected one refund and one order-edit adjustment, got %',v_count; END IF;

  SELECT amount INTO v_amount FROM henvalt.revenue_ledger WHERE id=(v_result->>'adjustment_id')::uuid;
  IF v_amount <> -10 THEN RAISE EXCEPTION 'order-edit ledger adjustment sign/value incorrect'; END IF;
  SELECT henvalt_fee INTO v_fee FROM henvalt.billing_measurements
   WHERE ledger_entry_id=(v_result->>'adjustment_id')::uuid;
  IF v_fee <> -1 THEN RAISE EXCEPTION 'order-edit adjustment did not create the expected negative fee measurement'; END IF;

  -- Replay of the same event cannot create a second adjustment.
  v_result := henvalt.process_shopify_order_edit_adjustment(v_edit_1);
  IF v_result->>'status' <> 'no_additional_downward_adjustment' THEN
    RAISE EXCEPTION 'order-edit replay was not idempotent: %',v_result;
  END IF;

  -- A second downward edit adds only the incremental delta, not the full delta.
  INSERT INTO henvalt.canonical_events(
    id,tenant_id,event_type,event_class,source,source_event_id,
    occurred_at,payload,metadata,idempotency_key
  ) VALUES(
    v_edit_2,v_tenant,'orders/updated','ADJUSTMENT','shopify',
    'order-edit-delivery-2',now(),
    '{"id":"order-edit-100","total_price":"100.00","current_total_price":"60.00","currency":"USD"}',
    '{}','order-edit-idem-2'
  );
  v_result := henvalt.process_shopify_order_edit_adjustment(v_edit_2);
  IF v_result->>'status' <> 'adjusted' OR (v_result->>'amount')::numeric <> 10 THEN
    RAISE EXCEPTION 'second order edit did not create only incremental 10 adjustment: %',v_result;
  END IF;

  -- Upward edits are deliberately conservative: they never reverse an issued
  -- credit or increase attributed recovered revenue above the original amount.
  INSERT INTO henvalt.canonical_events(
    id,tenant_id,event_type,event_class,source,source_event_id,
    occurred_at,payload,metadata,idempotency_key
  ) VALUES(
    v_edit_3,v_tenant,'orders/updated','ADJUSTMENT','shopify',
    'order-edit-delivery-3',now(),
    '{"id":"order-edit-100","total_price":"100.00","current_total_price":"90.00","currency":"USD"}',
    '{}','order-edit-idem-3'
  );
  v_result := henvalt.process_shopify_order_edit_adjustment(v_edit_3);
  IF v_result->>'status' <> 'no_additional_downward_adjustment' THEN
    RAISE EXCEPTION 'upward order edit unexpectedly reversed prior credit: %',v_result;
  END IF;

  SELECT COALESCE(ABS(sum(amount)),0) INTO v_total FROM henvalt.revenue_ledger
   WHERE tenant_id=v_tenant AND order_id=v_order AND entry_type='ADJUSTMENT';
  IF v_total <> 40 THEN RAISE EXCEPTION 'order edit/refund adjustments did not remain monotonic'; END IF;

  -- A confirmed recovery that was never measured must not create a fee credit.
  INSERT INTO henvalt.orders(id,tenant_id,shopify_order_id,total_value,currency,metadata)
  VALUES(v_order_2,v_tenant,'order-edit-unbilled',100,'USD','{}');
  INSERT INTO henvalt.revenue_ledger(
    id,tenant_id,order_id,entry_type,amount,currency,
    attribution_confidence,billable,billing_status,metadata
  ) VALUES(
    v_recovery_2,v_tenant,v_order_2,'RECOVERY',100,'USD',
    'CONFIRMED',true,'PENDING','{}'
  );
  INSERT INTO henvalt.canonical_events(
    id,tenant_id,event_type,event_class,source,source_event_id,
    occurred_at,payload,metadata,idempotency_key
  ) VALUES(
    v_edit_4,v_tenant,'orders/updated','ADJUSTMENT','shopify',
    'order-edit-delivery-4',now(),
    '{"id":"order-edit-unbilled","total_price":"100.00","current_total_price":"80.00","currency":"USD"}',
    '{}','order-edit-idem-4'
  );
  v_result := henvalt.process_shopify_order_edit_adjustment(v_edit_4);
  IF v_result->>'status' <> 'adjusted' THEN
    RAISE EXCEPTION 'unmeasured order should still reconcile revenue: %',v_result;
  END IF;
  IF EXISTS(SELECT 1 FROM henvalt.billing_measurements WHERE ledger_entry_id=(v_result->>'adjustment_id')::uuid) THEN
    RAISE EXCEPTION 'unbilled original recovery incorrectly generated a fee credit';
  END IF;

  -- Existing pre-migration adjustments are repaired on an idempotent retry,
  -- but only if their original confirmed recovery had a measured positive fee.
  INSERT INTO henvalt.orders(id,tenant_id,shopify_order_id,total_value,currency,metadata)
  VALUES(v_order_3,v_tenant,'order-edit-backfill',100,'USD','{}');
  INSERT INTO henvalt.revenue_ledger(
    id,tenant_id,order_id,entry_type,amount,currency,
    attribution_confidence,billable,billing_status,metadata
  ) VALUES(
    v_recovery_3,v_tenant,v_order_3,'RECOVERY',100,'USD',
    'CONFIRMED',true,'MEASURED','{}'
  );
  INSERT INTO henvalt.billing_measurements(
    tenant_id,billing_period_id,ledger_entry_id,recovered_revenue,
    henvalt_percentage,henvalt_fee,currency,status
  ) VALUES(
    v_tenant,gen_random_uuid(),v_recovery_3,100,10,10,'USD','MEASURED'
  );
  INSERT INTO henvalt.revenue_ledger(
    id,tenant_id,order_id,entry_type,amount,currency,
    attribution_confidence,billable,billing_status,metadata
  ) VALUES(
    v_existing_adjustment,v_tenant,v_order_3,'ADJUSTMENT',-5,'USD',
    'CONFIRMED',true,'PENDING',
    jsonb_build_object('source_event_id',v_backfill_event::text,'reason','LEGACY_REFUND')
  );
  PERFORM henvalt.create_revenue_adjustment(
    v_order_3,1,'USD','LEGACY_REFUND_RETRY',v_backfill_event
  );
  SELECT henvalt_fee INTO v_fee FROM henvalt.billing_measurements
   WHERE ledger_entry_id=v_existing_adjustment;
  IF v_fee <> -0.5 THEN
    RAISE EXCEPTION 'idempotent adjustment retry did not backfill its negative fee measurement';
  END IF;

  -- The replay-only wrapper rejects stale leases before the order-edit mutation
  -- and permits the same event only with the exact current job/worker/lease tuple.
  INSERT INTO henvalt.orders(id,tenant_id,shopify_order_id,total_value,currency,metadata)
  VALUES(v_order_4,v_tenant,'order-edit-fenced',100,'USD','{}');
  INSERT INTO henvalt.revenue_ledger(
    id,tenant_id,order_id,entry_type,amount,currency,
    attribution_confidence,billable,billing_status,metadata
  ) VALUES(
    v_recovery_4,v_tenant,v_order_4,'RECOVERY',100,'USD',
    'CONFIRMED',true,'PENDING','{}'
  );
  INSERT INTO henvalt.canonical_events(
    id,tenant_id,event_type,event_class,source,source_event_id,
    occurred_at,payload,metadata,idempotency_key
  ) VALUES(
    v_edit_5,v_tenant,'orders/updated','ADJUSTMENT','shopify',
    'order-edit-delivery-fenced',now(),
    '{"id":"order-edit-fenced","total_price":"100.00","current_total_price":"90.00","currency":"USD"}',
    '{}','order-edit-idem-fenced'
  );
  INSERT INTO henvalt.background_jobs(
    id,tenant_id,job_type,payload,status,locked_by,lease_id,lease_expires_at
  ) VALUES(
    v_job,v_tenant,'process_shopify_webhook','{}','CLAIMED',
    'order-edit-worker',v_lease,now()+interval '5 minutes'
  );

  BEGIN
    PERFORM henvalt.process_shopify_order_edit_adjustment_fenced(
      v_job,'order-edit-worker','eeeeeeee-eeee-4eee-8eee-eeeeeeee0322',v_edit_5
    );
    RAISE EXCEPTION 'stale replay lease unexpectedly allowed an order-edit write';
  EXCEPTION WHEN insufficient_privilege THEN
    NULL;
  END;

  IF EXISTS(
    SELECT 1 FROM henvalt.revenue_ledger
     WHERE tenant_id=v_tenant AND order_id=v_order_4 AND entry_type='ADJUSTMENT'
  ) THEN
    RAISE EXCEPTION 'stale replay lease mutated the order-edit revenue ledger';
  END IF;

  v_result := henvalt.process_shopify_order_edit_adjustment_fenced(
    v_job,'order-edit-worker',v_lease,v_edit_5
  );
  IF v_result->>'status' <> 'adjusted' OR (v_result->>'amount')::numeric <> 10 THEN
    RAISE EXCEPTION 'valid replay lease did not permit order-edit reconciliation: %',v_result;
  END IF;
END;
$shopify_order_edit_acceptance$;

ROLLBACK;

SELECT 'SHOPIFY_ORDER_EDIT_REVENUE_RECONCILIATION_ACCEPTANCE_PASSED' AS result;

\set ON_ERROR_STOP on
DO $accept$
DECLARE
  t_mixed uuid := '11111111-1111-4111-8111-111111111111';
  t_compare uuid := '22222222-2222-4222-8222-222222222222';
  t_empty uuid := '33333333-3333-4333-8333-333333333333';
  o_unverified uuid := 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa1';
  o_attributed uuid := 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa2';
  s jsonb;
  r jsonb;
  recovered_sum integer;
  v_item jsonb;
BEGIN
  INSERT INTO henvalt.tenants(id,name,status,default_currency) VALUES
    (t_mixed,'Mixed currency','ACTIVE','USD'),
    (t_compare,'Comparison currency','ACTIVE','USD'),
    (t_empty,'Empty ledger','ACTIVE','CAD');
  INSERT INTO henvalt.shopify_connections(id,tenant_id,shop_domain,active) VALUES
    ('44444444-4444-4444-8444-444444444441',t_mixed,'mixed.myshopify.com',true),
    ('44444444-4444-4444-8444-444444444442',t_compare,'compare.myshopify.com',true),
    ('44444444-4444-4444-8444-444444444443',t_empty,'empty.myshopify.com',true);

  INSERT INTO henvalt.opportunities(id,tenant_id,opportunity_type,status,value_at_risk,currency,created_at,updated_at) VALUES
    (o_unverified,t_mixed,'ABANDONED_CHECKOUT','RECOVERED',999,'USD','2026-11-15','2026-11-15'),
    (o_attributed,t_mixed,'ABANDONED_CART','ELIGIBLE',500,'GBP','2026-11-16','2026-11-16');

  INSERT INTO henvalt.order_attributions(id,tenant_id,order_id,opportunity_id,attribution_confidence,evaluated_at) VALUES
    ('55555555-5555-4555-8555-555555555551',t_mixed,'66666666-6666-4666-8666-666666666661',o_attributed,'CONFIRMED','2026-11-17'),
    ('55555555-5555-4555-8555-555555555552',t_mixed,'66666666-6666-4666-8666-666666666662',NULL,'CONFIRMED','2026-11-18');

  INSERT INTO henvalt.revenue_ledger(id,tenant_id,opportunity_id,entry_type,amount,currency,billable,attribution_confidence,created_at) VALUES
    ('77777777-7777-4777-8777-777777777771',t_mixed,o_attributed,'RECOVERY',100,'USD',true,'CONFIRMED','2026-11-17'),
    ('77777777-7777-4777-8777-777777777772',t_mixed,NULL,'RECOVERY',50,'GBP',true,'CONFIRMED','2026-11-18');

  INSERT INTO henvalt.revenue_ledger(id,tenant_id,opportunity_id,entry_type,amount,currency,billable,attribution_confidence,created_at) VALUES
    ('88888888-8888-4888-8888-888888888881',t_compare,NULL,'RECOVERY',30,'USD',true,'CONFIRMED','2026-11-17'),
    ('88888888-8888-4888-8888-888888888882',t_compare,NULL,'RECOVERY',20,'GBP',true,'CONFIRMED','2026-11-05');

  s := henvalt.control_plane_dashboard_summary('mixed.myshopify.com','2026-11-10','2026-11-20');
  IF s->>'revenueCurrencyConflict' IS DISTINCT FROM 'true' THEN
    RAISE EXCEPTION 'summary failed to flag mixed currencies: %',s;
  END IF;
  IF s#>>'{metrics,revenueRecovered}' IS NOT NULL THEN
    RAISE EXCEPTION 'summary returned a cross-currency numeric total';
  END IF;
  IF jsonb_array_length(s->'revenueByCurrency') <> 2 THEN
    RAISE EXCEPTION 'summary did not preserve per-currency totals';
  END IF;
  IF (s#>>'{metrics,recoveredOrders}')::integer <> 2 THEN
    RAISE EXCEPTION 'confirmed attribution order count is incorrect';
  END IF;
  SELECT sum((x->>'recovered')::integer) INTO recovered_sum
    FROM jsonb_array_elements(s->'byEvent') x;
  IF recovered_sum <> 2 THEN
    RAISE EXCEPTION 'by-event recovered counts do not reconcile to headline: %',recovered_sum;
  END IF;
  IF (SELECT (x->>'recovered')::integer FROM jsonb_array_elements(s->'byEvent') x WHERE x->>'eventType'='abandoned_cart') <> 1
     OR (SELECT (x->>'recovered')::integer FROM jsonb_array_elements(s->'byEvent') x WHERE x->>'eventType'='unclassified') <> 1 THEN
    RAISE EXCEPTION 'confirmed attribution categories are not classified correctly';
  END IF;
  SELECT x INTO v_item FROM jsonb_array_elements(s->'activity') x WHERE x->>'id'=o_unverified::text;
  IF v_item->>'outcome' <> 'unverified' THEN
    RAISE EXCEPTION 'RECOVERED opportunity without confirmed attribution was shown as recovered: %',v_item;
  END IF;
  SELECT x INTO v_item FROM jsonb_array_elements(s->'activity') x WHERE x->>'id'=o_attributed::text;
  IF v_item->>'outcome' <> 'recovered' THEN
    RAISE EXCEPTION 'confirmed attribution was not shown as recovered: %',v_item;
  END IF;

  r := henvalt.control_plane_revenue_series('mixed.myshopify.com','2026-11-10','2026-11-20','day');
  IF r->>'current_currency_conflict' IS DISTINCT FROM 'true'
     OR r->>'current_revenue' IS NOT NULL
     OR jsonb_array_length(r->'series') <> 0 THEN
    RAISE EXCEPTION 'mixed-currency revenue series was not withheld: %',r;
  END IF;

  s := henvalt.control_plane_dashboard_summary('compare.myshopify.com','2026-11-10','2026-11-20');
  IF s->>'revenueCurrencyConflict' IS DISTINCT FROM 'false'
     OR (s#>>'{metrics,revenueRecovered}')::numeric <> 30 THEN
    RAISE EXCEPTION 'single-currency summary should remain numeric: %',s;
  END IF;
  r := henvalt.control_plane_revenue_series('compare.myshopify.com','2026-11-10','2026-11-20','day');
  IF r->>'current_currency_conflict' IS DISTINCT FROM 'false'
     OR r->>'comparison_currency_conflict' IS DISTINCT FROM 'true'
     OR (r->>'current_revenue')::numeric <> 30
     OR r->>'previous_revenue' IS NOT NULL
     OR r->>'change_percent' IS NOT NULL THEN
    RAISE EXCEPTION 'cross-currency period comparison was not withheld: %',r;
  END IF;
  IF (SELECT sum((x->>'recovered_revenue')::numeric) FROM jsonb_array_elements(r->'series') x) <> 30 THEN
    RAISE EXCEPTION 'single-currency current trend was not preserved';
  END IF;

  s := henvalt.control_plane_dashboard_summary('empty.myshopify.com','2026-11-10','2026-11-20');
  IF s->>'currency' <> 'CAD'
     OR s->>'revenueCurrencyConflict' <> 'false'
     OR (s#>>'{metrics,revenueRecovered}')::numeric <> 0 THEN
    RAISE EXCEPTION 'empty ledger did not use tenant default currency and zero total: %',s;
  END IF;

  IF NOT has_function_privilege('service_role','henvalt.control_plane_dashboard_summary(text,timestamptz,timestamptz)','EXECUTE')
     OR has_function_privilege('anon','henvalt.control_plane_dashboard_summary(text,timestamptz,timestamptz)','EXECUTE')
     OR has_function_privilege('authenticated','henvalt.control_plane_dashboard_summary(text,timestamptz,timestamptz)','EXECUTE')
     OR NOT has_function_privilege('service_role','henvalt.control_plane_revenue_series(text,timestamptz,timestamptz,text)','EXECUTE')
     OR has_function_privilege('anon','henvalt.control_plane_revenue_series(text,timestamptz,timestamptz,text)','EXECUTE')
     OR has_function_privilege('authenticated','henvalt.control_plane_revenue_series(text,timestamptz,timestamptz,text)','EXECUTE') THEN
    RAISE EXCEPTION 'dashboard RPC grants are not service-role-only';
  END IF;
END
$accept$;
SELECT 'dashboard currency and attribution integrity acceptance passed' AS result;

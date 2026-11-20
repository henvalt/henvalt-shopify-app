-- Exact-store attribution and fee-ledger database integrity contract.
-- Runs after candidate migrations 001-060 in disposable PostgreSQL only.
-- This verifies database-enforced race boundaries, not production readiness.
\set ON_ERROR_STOP on

DO $attribution_integrity_v2$
DECLARE
  v_constraint record;
  v_missing text[] := ARRAY[]::text[];
  v_trigger_count integer;
  v_attribution_function text;
BEGIN
  FOR v_constraint IN
    SELECT * FROM (VALUES
      ('shopify_checkout_recovery_candidate_v2','shopify_checkout_recovery_candidate_v2_store_token_uidx'),
      ('shopify_recovery_opportunity_v2','shopify_recovery_opportunity_v2_candidate_uidx'),
      ('shopify_recovery_attributions_v2','shopify_recovery_attributions_v2_order_uidx'),
      ('shopify_recovery_attributions_v2','shopify_recovery_attributions_v2_opportunity_uidx'),
      ('shopify_recovery_fee_measurements_v2','shopify_recovery_fee_measurements_v2_attribution_uidx')
    ) AS expected(table_name,constraint_name)
  LOOP
    IF NOT EXISTS (
      SELECT 1
      FROM pg_catalog.pg_constraint c
      JOIN pg_catalog.pg_class t ON t.oid=c.conrelid
      JOIN pg_catalog.pg_namespace n ON n.oid=t.relnamespace
      WHERE n.nspname='henvalt'
        AND t.relname=v_constraint.table_name
        AND c.conname=v_constraint.constraint_name
        AND c.contype='u'
        AND c.convalidated
    ) THEN
      v_missing:=pg_catalog.array_append(v_missing,v_constraint.constraint_name);
    END IF;
  END LOOP;

  IF pg_catalog.cardinality(v_missing)>0 THEN
    RAISE EXCEPTION 'Missing validated unique attribution/fee constraints: %',v_missing;
  END IF;

  -- The unique opportunity index is the final concurrency barrier. The evaluator
  -- must also handle a losing INSERT explicitly instead of treating a conflict
  -- as a successful attribution. This is a function-definition contract; a
  -- separate two-session race test is still required to prove runtime behavior.
  SELECT pg_catalog.pg_get_functiondef(
    'henvalt.evaluate_shopify_recovery_attribution_v2(uuid)'::pg_catalog.regprocedure
  ) INTO v_attribution_function;

  IF pg_catalog.position('ON CONFLICT DO NOTHING' IN v_attribution_function)=0
     OR pg_catalog.position('OPPORTUNITY_ALREADY_ATTRIBUTED' IN v_attribution_function)=0
     OR pg_catalog.position('RETURN jsonb_build_object(''accepted'',false,''code'',''OPPORTUNITY_ALREADY_ATTRIBUTED'')' IN v_attribution_function)=0 THEN
    RAISE EXCEPTION 'Attribution evaluator no longer explicitly rejects a competing order after the unique opportunity conflict';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_catalog.pg_constraint c
    JOIN pg_catalog.pg_class t ON t.oid=c.conrelid
    JOIN pg_catalog.pg_namespace n ON n.oid=t.relnamespace
    WHERE n.nspname='henvalt'
      AND t.relname='shopify_recovery_attributions_v2'
      AND c.conname='shopify_recovery_attributions_v2_order_fkey'
      AND c.contype='f'
      AND pg_catalog.pg_get_constraintdef(c.oid) LIKE '%tenant_id%'
      AND pg_catalog.pg_get_constraintdef(c.oid) LIKE '%shopify_connection_id%'
  ) THEN
    RAISE EXCEPTION 'Attribution order foreign key does not preserve tenant/store lineage';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_catalog.pg_constraint c
    JOIN pg_catalog.pg_class t ON t.oid=c.conrelid
    JOIN pg_catalog.pg_namespace n ON n.oid=t.relnamespace
    WHERE n.nspname='henvalt'
      AND t.relname='shopify_recovery_attributions_v2'
      AND c.conname='shopify_recovery_attributions_v2_opportunity_fkey'
      AND c.contype='f'
      AND pg_catalog.pg_get_constraintdef(c.oid) LIKE '%tenant_id%'
      AND pg_catalog.pg_get_constraintdef(c.oid) LIKE '%shopify_connection_id%'
  ) THEN
    RAISE EXCEPTION 'Attribution opportunity foreign key does not preserve tenant/store lineage';
  END IF;

  SELECT count(*) INTO v_trigger_count
  FROM pg_catalog.pg_trigger tg
  JOIN pg_catalog.pg_class t ON t.oid=tg.tgrelid
  JOIN pg_catalog.pg_namespace n ON n.oid=t.relnamespace
  WHERE n.nspname='henvalt'
    AND tg.tgname IN (
      'shopify_recovery_attribution_fee_v2',
      'shopify_recovery_attribution_refund_reconcile_v2',
      'shopify_recovery_fee_measurement_billing_v2'
    )
    AND NOT tg.tgisinternal
    AND tg.tgenabled IN ('O','A');

  IF v_trigger_count<>3 THEN
    RAISE EXCEPTION 'Expected three enabled attribution/refund/billing triggers; found %',v_trigger_count;
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_catalog.pg_attribute a
    JOIN pg_catalog.pg_class t ON t.oid=a.attrelid
    JOIN pg_catalog.pg_namespace n ON n.oid=t.relnamespace
    WHERE n.nspname='henvalt'
      AND t.relname='shopify_recovery_fee_measurements_v2'
      AND a.attname='credit_amount'
      AND NOT a.attisdropped
  ) OR NOT EXISTS (
    SELECT 1 FROM pg_catalog.pg_attribute a
    JOIN pg_catalog.pg_class t ON t.oid=a.attrelid
    JOIN pg_catalog.pg_namespace n ON n.oid=t.relnamespace
    WHERE n.nspname='henvalt'
      AND t.relname='shopify_recovery_fee_measurements_v2'
      AND a.attname='reconciliation_status'
      AND NOT a.attisdropped
  ) THEN
    RAISE EXCEPTION 'Fee ledger is missing explicit refund-credit reconciliation fields';
  END IF;
END;
$attribution_integrity_v2$;

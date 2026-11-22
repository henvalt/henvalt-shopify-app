\set ON_ERROR_STOP on

BEGIN;

DO $ledger_promotion_acceptance$
DECLARE
  v_tenant uuid := 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaa01';
  v_order uuid := 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbb001';
  v_attribution uuid := 'cccccccc-cccc-4ccc-8ccc-cccccccc0001';
  v_unpaid_order uuid := 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbb002';
  v_cancelled_order uuid := 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbb003';
  v_possible_attribution uuid := 'cccccccc-cccc-4ccc-8ccc-cccccccc0002';
  v_unpaid_attribution uuid := 'cccccccc-cccc-4ccc-8ccc-cccccccc0003';
  v_cancelled_attribution uuid := 'cccccccc-cccc-4ccc-8ccc-cccccccc0004';
  v_ledger_id uuid;
  v_repeat_id uuid;
  v_rows integer;
  v_billable boolean;
  v_confidence henvalt.attribution_confidence;
  v_amount numeric(18,2);
BEGIN
  INSERT INTO henvalt.tenants(id, status, default_currency)
  VALUES (v_tenant, 'ACTIVE', 'USD');

  INSERT INTO henvalt.orders(
    id, tenant_id, total_value, currency, financial_status, cancelled_at, ordered_at
  ) VALUES
    (v_order, v_tenant, 149.95, 'USD', 'paid', NULL, now() - interval '1 day'),
    (v_unpaid_order, v_tenant, 49.00, 'USD', 'pending', NULL, now()),
    (v_cancelled_order, v_tenant, 25.00, 'USD', 'paid', now(), now());

  INSERT INTO henvalt.order_attributions(
    id, tenant_id, order_id, attribution_confidence, attributed_value
  ) VALUES
    (v_attribution, v_tenant, v_order, 'PROBABLE', 149.95),
    (v_possible_attribution, v_tenant, v_order, 'POSSIBLE', 149.95),
    (v_unpaid_attribution, v_tenant, v_unpaid_order, 'CONFIRMED', 49.00),
    (v_cancelled_attribution, v_tenant, v_cancelled_order, 'CONFIRMED', 25.00);

  -- First evaluation is only PROBABLE: analytics ledger row, not billable.
  v_ledger_id := henvalt.post_recovery_to_ledger(v_attribution);
  IF v_ledger_id IS NULL THEN
    RAISE EXCEPTION 'probable recovery did not create its analytics ledger row';
  END IF;

  SELECT billable, attribution_confidence, amount
    INTO v_billable, v_confidence, v_amount
    FROM henvalt.revenue_ledger WHERE id = v_ledger_id;

  IF v_billable IS TRUE OR v_confidence <> 'PROBABLE' OR v_amount <> 149.95 THEN
    RAISE EXCEPTION 'probable recovery was incorrectly made billable or mis-valued';
  END IF;

  -- Stronger tracked-click evidence arrives later for the same order.
  UPDATE henvalt.order_attributions
     SET attribution_confidence = 'CONFIRMED',
         attribution_method = 'tracking_token+recorded_click+provider_acceptance',
         tracking_token_matched = true,
         attributed_value = 149.95,
         evaluated_at = now()
   WHERE id = v_attribution;

  v_repeat_id := henvalt.post_recovery_to_ledger(v_attribution);
  IF v_repeat_id IS DISTINCT FROM v_ledger_id THEN
    RAISE EXCEPTION 'confirmation promotion created a duplicate ledger row';
  END IF;

  SELECT billable, attribution_confidence, amount
    INTO v_billable, v_confidence, v_amount
    FROM henvalt.revenue_ledger WHERE id = v_ledger_id;

  IF v_billable IS NOT TRUE OR v_confidence <> 'CONFIRMED' OR v_amount <> 149.95 THEN
    RAISE EXCEPTION 'probable ledger row was not promoted to confirmed billable revenue';
  END IF;

  -- A later weaker evaluation must never downgrade confirmed financial proof.
  UPDATE henvalt.order_attributions
     SET attribution_confidence = 'PROBABLE',
         tracking_token_matched = false
   WHERE id = v_attribution;
  PERFORM henvalt.post_recovery_to_ledger(v_attribution);

  SELECT billable, attribution_confidence
    INTO v_billable, v_confidence
    FROM henvalt.revenue_ledger WHERE id = v_ledger_id;
  IF v_billable IS NOT TRUE OR v_confidence <> 'CONFIRMED' THEN
    RAISE EXCEPTION 'confirmed recovery ledger was downgraded by weaker evidence';
  END IF;

  SELECT count(*) INTO v_rows
    FROM henvalt.revenue_ledger
   WHERE tenant_id = v_tenant AND order_id = v_order AND entry_type = 'RECOVERY';
  IF v_rows <> 1 THEN
    RAISE EXCEPTION 'expected exactly one recovery ledger row per order, got %', v_rows;
  END IF;

  IF henvalt.post_recovery_to_ledger(v_possible_attribution) IS NOT NULL THEN
    RAISE EXCEPTION 'POSSIBLE customer-only attribution created a ledger row';
  END IF;
  IF henvalt.post_recovery_to_ledger(v_unpaid_attribution) IS NOT NULL THEN
    RAISE EXCEPTION 'unpaid order created recovery revenue';
  END IF;
  IF henvalt.post_recovery_to_ledger(v_cancelled_attribution) IS NOT NULL THEN
    RAISE EXCEPTION 'cancelled order created recovery revenue';
  END IF;
END;
$ledger_promotion_acceptance$;

ROLLBACK;

SELECT 'REVENUE_LEDGER_CONFIRMED_PROMOTION_ACCEPTANCE_PASSED' AS result;

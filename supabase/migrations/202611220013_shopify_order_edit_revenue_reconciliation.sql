-- Reconcile Shopify order edits against confirmed recovered revenue.
-- Downward edits create immutable negative adjustments; upward edits never
-- increase attributed revenue above the originally recovered checkout value.
-- Adjustment fee measurements are created only when the original recovery
-- already had a positive billing measurement, preventing credits for fees
-- HENVALT never measured.

BEGIN;

CREATE OR REPLACE FUNCTION henvalt.create_revenue_adjustment(
  p_order_id uuid,
  p_amount numeric,
  p_currency character,
  p_reason text,
  p_source_event_id uuid
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'henvalt', 'public', 'pg_temp'
AS $function$
DECLARE
  v_tenant_id uuid;
  v_recovery_id uuid;
  v_opportunity_id uuid;
  v_attribution_id uuid;
  v_recovery_ledger_id uuid;
  v_recovery_currency char(3);
  v_original_amount numeric(18,2);
  v_existing uuid;
  v_adjustment_id uuid;
  v_previously_adjusted numeric(18,2);
  v_remaining numeric(18,2);
  v_percentage numeric(7,4);
BEGIN
  IF p_order_id IS NULL THEN
    RAISE EXCEPTION 'Order is required';
  END IF;
  IF p_source_event_id IS NULL THEN
    RAISE EXCEPTION 'Source event is required for idempotent adjustment';
  END IF;
  IF p_amount IS NULL OR p_amount <= 0 THEN
    RAISE EXCEPTION 'Adjustment amount must be greater than zero';
  END IF;
  IF p_currency IS NULL OR length(trim(p_currency)) <> 3 THEN
    RAISE EXCEPTION 'Adjustment currency must be a 3-letter currency code';
  END IF;
  IF p_reason IS NULL OR length(trim(p_reason)) = 0 THEN
    RAISE EXCEPTION 'Adjustment reason is required';
  END IF;

  SELECT rl.id
    INTO v_existing
    FROM henvalt.revenue_ledger rl
   WHERE rl.entry_type = 'ADJUSTMENT'
     AND rl.metadata->>'source_event_id' = p_source_event_id::text
   LIMIT 1;
  IF v_existing IS NOT NULL THEN
    -- Backfill a missing fee measurement on retry after this migration. This
    -- is safe only when the original confirmed recovery had a positive
    -- measurement, and the unique ledger-measurement key makes it idempotent.
    SELECT rl.tenant_id, rl.order_id
      INTO v_tenant_id, p_order_id
      FROM henvalt.revenue_ledger rl
     WHERE rl.id = v_existing;

    SELECT rl.id
      INTO v_recovery_ledger_id
      FROM henvalt.revenue_ledger rl
     WHERE rl.tenant_id = v_tenant_id
       AND rl.order_id = p_order_id
       AND rl.entry_type = 'RECOVERY'
       AND rl.billable = true
       AND rl.attribution_confidence = 'CONFIRMED'
     ORDER BY rl.created_at ASC
     LIMIT 1;

    SELECT bm.henvalt_percentage
      INTO v_percentage
      FROM henvalt.billing_measurements bm
     WHERE bm.tenant_id = v_tenant_id
       AND bm.ledger_entry_id = v_recovery_ledger_id
       AND bm.henvalt_fee > 0
     ORDER BY bm.created_at ASC
     LIMIT 1;

    IF v_percentage IS NOT NULL
       AND NOT EXISTS (
         SELECT 1 FROM henvalt.billing_measurements bm
          WHERE bm.tenant_id = v_tenant_id
            AND bm.ledger_entry_id = v_existing
       ) THEN
      PERFORM henvalt.measure_billing_entry(v_existing, v_percentage);
    END IF;
    RETURN v_existing;
  END IF;

  SELECT rl.id, rl.tenant_id, rl.recovery_id, rl.opportunity_id,
         rl.attribution_id, rl.currency, rl.amount
    INTO v_recovery_ledger_id, v_tenant_id, v_recovery_id, v_opportunity_id,
         v_attribution_id, v_recovery_currency, v_original_amount
    FROM henvalt.revenue_ledger rl
   WHERE rl.order_id = p_order_id
     AND rl.entry_type = 'RECOVERY'
     AND rl.billable = true
     AND rl.attribution_confidence = 'CONFIRMED'
   ORDER BY rl.created_at ASC
   LIMIT 1
   FOR UPDATE;

  IF v_tenant_id IS NULL THEN
    RETURN NULL;
  END IF;

  IF upper(trim(p_currency)) <> upper(trim(v_recovery_currency)) THEN
    RAISE EXCEPTION 'Adjustment currency does not match recovery currency';
  END IF;

  SELECT COALESCE(ABS(SUM(rl.amount)), 0)
    INTO v_previously_adjusted
    FROM henvalt.revenue_ledger rl
   WHERE rl.tenant_id = v_tenant_id
     AND rl.order_id = p_order_id
     AND rl.entry_type = 'ADJUSTMENT';

  v_remaining := v_original_amount - v_previously_adjusted;
  IF p_amount > v_remaining THEN
    RAISE EXCEPTION 'Adjustment exceeds remaining recovered order value (remaining=%)', v_remaining;
  END IF;

  INSERT INTO henvalt.revenue_ledger (
    tenant_id, order_id, recovery_id, opportunity_id, attribution_id,
    entry_type, amount, currency, attribution_confidence, billable,
    billing_status, metadata
  )
  VALUES (
    v_tenant_id, p_order_id, v_recovery_id, v_opportunity_id, v_attribution_id,
    'ADJUSTMENT', -ABS(p_amount), upper(trim(p_currency)), 'CONFIRMED', true,
    'PENDING',
    jsonb_build_object(
      'reason', p_reason,
      'source_event_id', p_source_event_id::text,
      'adjustment_type', 'REFUND_OR_ORDER_CHANGE'
    )
  )
  ON CONFLICT (tenant_id, (metadata->>'source_event_id'))
    WHERE entry_type = 'ADJUSTMENT' AND metadata ? 'source_event_id'
  DO NOTHING
  RETURNING id INTO v_adjustment_id;

  IF v_adjustment_id IS NULL THEN
    SELECT rl.id INTO v_adjustment_id
      FROM henvalt.revenue_ledger rl
     WHERE rl.tenant_id = v_tenant_id
       AND rl.entry_type = 'ADJUSTMENT'
       AND rl.metadata->>'source_event_id' = p_source_event_id::text
     LIMIT 1;
  END IF;

  -- Only issue a fee credit if the original recovered order had a measured
  -- positive fee. An order that was never billed must not create a credit.
  SELECT bm.henvalt_percentage
    INTO v_percentage
    FROM henvalt.billing_measurements bm
   WHERE bm.tenant_id = v_tenant_id
     AND bm.ledger_entry_id = v_recovery_ledger_id
     AND bm.henvalt_fee > 0
   ORDER BY bm.created_at ASC
   LIMIT 1;

  IF v_percentage IS NOT NULL AND v_adjustment_id IS NOT NULL THEN
    PERFORM henvalt.measure_billing_entry(v_adjustment_id, v_percentage);
  END IF;

  RETURN v_adjustment_id;
END;
$function$;

CREATE OR REPLACE FUNCTION henvalt.process_shopify_order_edit_adjustment(p_event_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'henvalt', 'public', 'pg_temp'
AS $function$
DECLARE
  v_event henvalt.canonical_events%ROWTYPE;
  v_shopify_order_id text;
  v_order_id uuid;
  v_order_currency char(3);
  v_current_total numeric(18,2);
  v_currency text;
  v_recovery_ledger_id uuid;
  v_original_amount numeric(18,2);
  v_previously_adjusted numeric(18,2);
  v_target_adjustment numeric(18,2);
  v_delta numeric(18,2);
  v_adjustment_id uuid;
BEGIN
  SELECT *
    INTO v_event
    FROM henvalt.canonical_events
   WHERE id = p_event_id
   FOR UPDATE;

  IF NOT FOUND OR v_event.source <> 'shopify' THEN
    RAISE EXCEPTION 'Shopify canonical event not found';
  END IF;

  IF lower(v_event.event_type) <> 'orders/updated' THEN
    RETURN jsonb_build_object('status','ignored_topic','event_id',p_event_id);
  END IF;

  v_shopify_order_id := NULLIF(v_event.payload->>'id','');
  IF v_shopify_order_id IS NULL THEN
    RAISE EXCEPTION 'Shopify order id missing from order update';
  END IF;

  -- Shopify's current_total_price is authoritative after order edits/refunds.
  -- Prefer its money-set representation when present; never prefer stale
  -- total_price over the current total.
  v_current_total := NULLIF(COALESCE(
    v_event.payload->>'current_total_price',
    v_event.payload->'current_total_price_set'->'shop_money'->>'amount',
    v_event.payload->>'total_price',
    v_event.payload->'total_price_set'->'shop_money'->>'amount'
  ),'')::numeric;

  IF v_current_total IS NULL OR v_current_total < 0 THEN
    RAISE EXCEPTION 'Shopify current order total is missing or invalid';
  END IF;

  v_currency := upper(trim(COALESCE(
    NULLIF(v_event.payload->'current_total_price_set'->'shop_money'->>'currency_code',''),
    NULLIF(v_event.payload->>'currency',''),
    NULLIF(v_event.payload->>'presentment_currency','')
  )));
  IF v_currency IS NULL OR length(v_currency) <> 3 THEN
    RAISE EXCEPTION 'Shopify order currency is missing or invalid';
  END IF;

  SELECT o.id, o.currency
    INTO v_order_id, v_order_currency
    FROM henvalt.orders o
   WHERE o.tenant_id = v_event.tenant_id
     AND o.shopify_order_id = v_shopify_order_id
   LIMIT 1
   FOR UPDATE;

  IF v_order_id IS NULL THEN
    RETURN jsonb_build_object('status','no_matching_order','event_id',p_event_id);
  END IF;

  IF v_order_currency IS NOT NULL AND upper(trim(v_order_currency::text)) <> v_currency THEN
    RAISE EXCEPTION 'Shopify order edit currency does not match projected order currency';
  END IF;

  UPDATE henvalt.orders
     SET total_value = v_current_total,
         currency = v_currency,
         updated_at = now()
   WHERE id = v_order_id
     AND tenant_id = v_event.tenant_id;

  SELECT rl.id, rl.amount
    INTO v_recovery_ledger_id, v_original_amount
    FROM henvalt.revenue_ledger rl
   WHERE rl.tenant_id = v_event.tenant_id
     AND rl.order_id = v_order_id
     AND rl.entry_type = 'RECOVERY'
     AND rl.billable = true
     AND rl.attribution_confidence = 'CONFIRMED'
   ORDER BY rl.created_at ASC
   LIMIT 1
   FOR UPDATE;

  IF v_recovery_ledger_id IS NULL THEN
    RETURN jsonb_build_object(
      'status','order_projected_without_confirmed_recovery',
      'event_id',p_event_id,
      'current_total',v_current_total,
      'currency',v_currency
    );
  END IF;

  IF upper(trim(v_order_currency::text)) <> v_currency THEN
    RAISE EXCEPTION 'Order edit currency does not match confirmed recovery currency';
  END IF;

  SELECT COALESCE(ABS(SUM(rl.amount)),0)
    INTO v_previously_adjusted
    FROM henvalt.revenue_ledger rl
   WHERE rl.tenant_id = v_event.tenant_id
     AND rl.order_id = v_order_id
     AND rl.entry_type = 'ADJUSTMENT';

  -- Downward-only, monotonic reconciliation: never bill above the originally
  -- attributed recovery value. Existing refund adjustments count toward the
  -- target so an orders/updated webhook following refunds/create cannot double
  -- credit the same reduction. Upward edits are deliberately not re-billed.
  v_target_adjustment := GREATEST(v_original_amount - LEAST(v_current_total, v_original_amount), 0);
  v_delta := GREATEST(v_target_adjustment - v_previously_adjusted, 0);

  IF v_delta <= 0 THEN
    RETURN jsonb_build_object(
      'status','no_additional_downward_adjustment',
      'event_id',p_event_id,
      'current_total',v_current_total,
      'already_adjusted',v_previously_adjusted
    );
  END IF;

  v_adjustment_id := henvalt.create_revenue_adjustment(
    v_order_id,
    v_delta,
    v_currency::char(3),
    'SHOPIFY_ORDER_EDIT_DOWNWARD_ADJUSTMENT',
    p_event_id
  );

  RETURN jsonb_build_object(
    'status',CASE WHEN v_adjustment_id IS NULL THEN 'not_adjusted' ELSE 'adjusted' END,
    'adjustment_id',v_adjustment_id,
    'amount',v_delta,
    'currency',v_currency,
    'current_total',v_current_total,
    'event_id',p_event_id
  );
END;
$function$;

REVOKE ALL ON FUNCTION henvalt.process_shopify_order_edit_adjustment(uuid)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION henvalt.process_shopify_order_edit_adjustment(uuid)
  TO service_role;

COMMIT;

-- Reconcile Shopify order edits against confirmed recovered revenue.
-- Downward edits create immutable negative adjustments; upward edits never
-- increase attributed revenue above the originally recovered checkout value.
-- Adjustment fee measurements are created only when the original recovery
-- already had a positive billing measurement, preventing credits for fees
-- HENVALT never measured.

BEGIN;

CREATE OR REPLACE FUNCTION henvalt.project_order_from_event(p_event_id uuid)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_tenant_id uuid;
  v_payload jsonb;
  v_order_id text;
  v_order_number text;
  v_email text;
  v_checkout_id text;
  v_checkout_token text;
  v_landing_site text;
  v_tracking_token text;
  v_total numeric(18,2);
  v_currency char(3);
  v_financial_status text;
  v_fulfillment_status text;
  v_ordered_at timestamptz;
  v_cancelled_at timestamptz;
  v_customer_id uuid;
  v_checkout_uuid uuid;
  v_existing uuid;
BEGIN
  SELECT tenant_id,payload
    INTO v_tenant_id,v_payload
    FROM henvalt.canonical_events
   WHERE id=p_event_id;

  IF v_tenant_id IS NULL THEN
    RAISE EXCEPTION 'Canonical event not found';
  END IF;

  v_order_id := COALESCE(v_payload->>'id',v_payload->>'order_id');
  IF v_order_id IS NULL OR trim(v_order_id)='' THEN
    RAISE EXCEPTION 'Shopify order id missing';
  END IF;

  SELECT id INTO v_existing
    FROM henvalt.orders
   WHERE tenant_id=v_tenant_id
     AND shopify_order_id=v_order_id;

  v_order_number := v_payload->>'order_number';
  v_email := lower(trim(COALESCE(v_payload->>'email',v_payload->'customer'->>'email')));
  v_checkout_id := COALESCE(v_payload->>'checkout_id',v_payload->'checkout'->>'id');
  v_checkout_token := COALESCE(v_payload->>'checkout_token',v_payload->'checkout'->>'token');

  -- Shopify current_total_price is the authoritative post-edit value. The
  -- original total_price is only a fallback for older webhook payloads.
  v_total := NULLIF(COALESCE(
    v_payload->>'current_total_price',
    v_payload->'current_total_price_set'->'shop_money'->>'amount',
    v_payload->>'total_price',
    v_payload->'total_price_set'->'shop_money'->>'amount'
  ),'')::numeric;

  v_currency := LEFT(COALESCE(
    v_payload->'current_total_price_set'->'shop_money'->>'currency_code',
    v_payload->>'currency',
    v_payload->>'presentment_currency'
  ),3)::char(3);
  v_financial_status := v_payload->>'financial_status';
  v_fulfillment_status := v_payload->>'fulfillment_status';
  v_ordered_at := COALESCE(NULLIF(v_payload->>'created_at','')::timestamptz,now());
  v_cancelled_at := NULLIF(v_payload->>'cancelled_at','')::timestamptz;
  v_landing_site := COALESCE(
    v_payload->>'landing_site',
    v_payload->>'landing_site_ref',
    v_payload->'client_details'->>'landing_page'
  );
  v_tracking_token := COALESCE(
    NULLIF(v_payload->>'henvalt_tracking_token',''),
    NULLIF(v_payload->>'tracking_token',''),
    (regexp_match(COALESCE(v_landing_site,''),'[?&]henvalt_token=([0-9a-f]{48})(?:&|$)'))[1]
  );

  SELECT id INTO v_customer_id
    FROM henvalt.customers
   WHERE tenant_id=v_tenant_id
     AND (
       lower(email)=v_email
       OR shopify_customer_id=COALESCE(v_payload->'customer'->>'id',v_payload->>'customer_id')
     )
   ORDER BY
     CASE WHEN shopify_customer_id=COALESCE(v_payload->'customer'->>'id',v_payload->>'customer_id')
       THEN 1 ELSE 2 END,
     created_at DESC
   LIMIT 1;

  IF v_checkout_id IS NOT NULL THEN
    SELECT id INTO v_checkout_uuid
      FROM henvalt.checkouts
     WHERE tenant_id=v_tenant_id
       AND shopify_checkout_id=v_checkout_id
     LIMIT 1;
  END IF;

  IF v_existing IS NOT NULL THEN
    UPDATE henvalt.orders
       SET customer_id=COALESCE(v_customer_id,customer_id),
           checkout_id=COALESCE(v_checkout_uuid,checkout_id),
           order_number=COALESCE(v_order_number,order_number),
           total_value=COALESCE(v_total,total_value),
           currency=COALESCE(v_currency,currency),
           financial_status=COALESCE(v_financial_status,financial_status),
           fulfillment_status=COALESCE(v_fulfillment_status,fulfillment_status),
           ordered_at=COALESCE(v_ordered_at,ordered_at),
           cancelled_at=COALESCE(v_cancelled_at,cancelled_at),
           tracking_token=COALESCE(v_tracking_token,tracking_token),
           metadata=COALESCE(metadata,'{}'::jsonb)||jsonb_build_object(
             'checkout_token',v_checkout_token,
             'henvalt_tracking_token',v_tracking_token,
             'landing_site',v_landing_site,
             'last_event_id',p_event_id
           ),
           updated_at=now()
     WHERE id=v_existing;
    RETURN v_existing;
  END IF;

  INSERT INTO henvalt.orders(
    tenant_id,customer_id,checkout_id,shopify_order_id,order_number,
    total_value,currency,financial_status,fulfillment_status,ordered_at,
    cancelled_at,tracking_token,metadata
  ) VALUES (
    v_tenant_id,v_customer_id,v_checkout_uuid,v_order_id,v_order_number,
    COALESCE(v_total,0),v_currency,v_financial_status,v_fulfillment_status,
    v_ordered_at,v_cancelled_at,v_tracking_token,
    jsonb_build_object(
      'checkout_token',v_checkout_token,
      'henvalt_tracking_token',v_tracking_token,
      'landing_site',v_landing_site,
      'source_event_id',p_event_id
    )
  )
  RETURNING id INTO v_existing;

  RETURN v_existing;
END;
$function$;

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
SET search_path = ''
AS $function$
DECLARE
  v_tenant_id uuid;
  v_recovery_id uuid;
  v_opportunity_id uuid;
  v_attribution_id uuid;
  v_recovery_ledger_id uuid;
  v_adjustment_order_id uuid;
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
      INTO v_tenant_id, v_adjustment_order_id
      FROM henvalt.revenue_ledger rl
     WHERE rl.id = v_existing;

    SELECT rl.id
      INTO v_recovery_ledger_id
      FROM henvalt.revenue_ledger rl
     WHERE rl.tenant_id = v_tenant_id
       AND rl.order_id = v_adjustment_order_id
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
SET search_path = ''
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


CREATE OR REPLACE FUNCTION henvalt.process_shopify_order_edit_adjustment_fenced(
  p_job_id uuid,
  p_worker_id text,
  p_lease_id uuid,
  p_event_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
BEGIN
  PERFORM henvalt.assert_shopify_replay_lease_for_write(p_job_id,p_worker_id,p_lease_id);
  RETURN henvalt.process_shopify_order_edit_adjustment(p_event_id);
END;
$function$;

REVOKE ALL ON FUNCTION henvalt.process_shopify_order_edit_adjustment_fenced(uuid,text,uuid,uuid)
  FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION henvalt.process_shopify_order_edit_adjustment_fenced(uuid,text,uuid,uuid)
  FROM anon,authenticated;
GRANT EXECUTE ON FUNCTION henvalt.process_shopify_order_edit_adjustment_fenced(uuid,text,uuid,uuid)
  TO service_role;

COMMIT;

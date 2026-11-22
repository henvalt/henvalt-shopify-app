-- Promote an existing probable recovery ledger row when later evidence
-- upgrades the same order attribution to CONFIRMED. Never downgrade a
-- previously confirmed row. Candidate migration only; staging acceptance first.

BEGIN;

CREATE OR REPLACE FUNCTION henvalt.post_recovery_to_ledger(p_attribution_id uuid)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, henvalt, pg_temp
AS $function$
DECLARE
  v_tenant_id uuid;
  v_order_id uuid;
  v_recovery_id uuid;
  v_opportunity_id uuid;
  v_confidence text;
  v_amount numeric(18,2);
  v_currency char(3);
  v_financial_status text;
  v_cancelled_at timestamptz;
  v_existing_id uuid;
  v_existing_confidence text;
  v_existing_billable boolean;
  v_ledger_id uuid;
BEGIN
  -- Serialize attribution promotion and ledger creation for the order.
  SELECT
    oa.tenant_id,
    oa.order_id,
    oa.recovery_id,
    oa.opportunity_id,
    oa.attribution_confidence::text,
    oa.attributed_value,
    o.currency,
    o.financial_status,
    o.cancelled_at
  INTO
    v_tenant_id,
    v_order_id,
    v_recovery_id,
    v_opportunity_id,
    v_confidence,
    v_amount,
    v_currency,
    v_financial_status,
    v_cancelled_at
  FROM henvalt.order_attributions oa
  JOIN henvalt.orders o
    ON o.id = oa.order_id
   AND o.tenant_id = oa.tenant_id
  WHERE oa.id = p_attribution_id
  FOR UPDATE OF oa, o;

  IF v_tenant_id IS NULL THEN
    RAISE EXCEPTION 'Attribution not found';
  END IF;

  -- Recovery revenue is posted only for paid, non-cancelled orders.
  IF lower(COALESCE(v_financial_status, '')) <> 'paid'
     OR v_cancelled_at IS NOT NULL THEN
    RETURN NULL;
  END IF;

  -- Customer-only POSSIBLE matches are diagnostic, never ledger revenue.
  IF v_confidence NOT IN ('CONFIRMED', 'PROBABLE') THEN
    RETURN NULL;
  END IF;

  IF v_amount IS NULL OR v_amount <= 0 THEN
    RETURN NULL;
  END IF;

  SELECT
    rl.id,
    rl.attribution_confidence::text,
    rl.billable
  INTO
    v_existing_id,
    v_existing_confidence,
    v_existing_billable
  FROM henvalt.revenue_ledger rl
  WHERE rl.tenant_id = v_tenant_id
    AND rl.order_id = v_order_id
    AND rl.entry_type = 'RECOVERY'
  FOR UPDATE;

  IF v_existing_id IS NOT NULL THEN
    -- Confidence is monotonic: a later weaker evaluation cannot erase
    -- a previously proven click-through recovery.
    IF v_confidence = 'CONFIRMED'
       AND (v_existing_confidence IS DISTINCT FROM 'CONFIRMED'
            OR v_existing_billable IS NOT TRUE) THEN
      UPDATE henvalt.revenue_ledger
         SET recovery_id = COALESCE(v_recovery_id, recovery_id),
             opportunity_id = COALESCE(v_opportunity_id, opportunity_id),
             attribution_id = p_attribution_id,
             amount = v_amount,
             currency = v_currency,
             attribution_confidence = 'CONFIRMED',
             billable = true,
             metadata = COALESCE(metadata, '{}'::jsonb) ||
               jsonb_build_object(
                 'attribution_promoted_at', now(),
                 'attribution_upgrade_from', v_existing_confidence::text,
                 'attribution_upgrade_to', 'CONFIRMED'
               )
       WHERE id = v_existing_id
         AND tenant_id = v_tenant_id
         AND order_id = v_order_id
         AND entry_type = 'RECOVERY';
    END IF;

    RETURN v_existing_id;
  END IF;

  INSERT INTO henvalt.revenue_ledger (
    tenant_id,
    order_id,
    recovery_id,
    opportunity_id,
    attribution_id,
    entry_type,
    amount,
    currency,
    attribution_confidence,
    billable,
    billing_status,
    metadata
  ) VALUES (
    v_tenant_id,
    v_order_id,
    v_recovery_id,
    v_opportunity_id,
    p_attribution_id,
    'RECOVERY',
    v_amount,
    v_currency,
    v_confidence::henvalt.attribution_confidence,
    v_confidence = 'CONFIRMED',
    'PENDING',
    jsonb_build_object(
      'source', 'order_attribution',
      'attribution_id', p_attribution_id,
      'attribution_confidence', v_confidence::text
    )
  )
  ON CONFLICT (tenant_id, order_id)
    WHERE entry_type = 'RECOVERY'
  DO NOTHING
  RETURNING id INTO v_ledger_id;

  IF v_ledger_id IS NOT NULL THEN
    RETURN v_ledger_id;
  END IF;

  -- A concurrent insert won the unique order/recovery key. Re-read under
  -- lock and apply the same monotonic promotion rule.
  SELECT rl.id, rl.attribution_confidence::text, rl.billable
    INTO v_existing_id, v_existing_confidence, v_existing_billable
    FROM henvalt.revenue_ledger rl
   WHERE rl.tenant_id = v_tenant_id
     AND rl.order_id = v_order_id
     AND rl.entry_type = 'RECOVERY'
   FOR UPDATE;

  IF v_existing_id IS NULL THEN
    RAISE EXCEPTION 'Recovery ledger upsert did not produce a row';
  END IF;

  IF v_confidence = 'CONFIRMED'
     AND (v_existing_confidence IS DISTINCT FROM 'CONFIRMED'
          OR v_existing_billable IS NOT TRUE) THEN
    UPDATE henvalt.revenue_ledger
       SET recovery_id = COALESCE(v_recovery_id, recovery_id),
           opportunity_id = COALESCE(v_opportunity_id, opportunity_id),
           attribution_id = p_attribution_id,
           amount = v_amount,
           currency = v_currency,
           attribution_confidence = 'CONFIRMED',
           billable = true,
           metadata = COALESCE(metadata, '{}'::jsonb) ||
             jsonb_build_object(
               'attribution_promoted_at', now(),
               'attribution_upgrade_from', v_existing_confidence::text,
               'attribution_upgrade_to', 'CONFIRMED'
             )
     WHERE id = v_existing_id
       AND tenant_id = v_tenant_id
       AND order_id = v_order_id
       AND entry_type = 'RECOVERY';
  END IF;

  RETURN v_existing_id;
END;
$function$;

REVOKE ALL ON FUNCTION henvalt.post_recovery_to_ledger(uuid)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION henvalt.post_recovery_to_ledger(uuid)
  TO service_role;

COMMENT ON FUNCTION henvalt.post_recovery_to_ledger(uuid) IS
  'Creates one recovery ledger row per paid order and monotonically promotes a prior PROBABLE row to billable CONFIRMED when stronger click-through evidence arrives.';

COMMIT;

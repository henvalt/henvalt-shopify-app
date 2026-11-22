-- Apply confirmed refund/cancellation credits to future positive Shopify usage charges.
-- Negative adjustment measurements must never be submitted as negative Shopify usage records.
-- Credits are allocated once, transactionally, and remain tenant/currency scoped.

BEGIN;

CREATE TABLE IF NOT EXISTS henvalt.billing_measurement_credit_offsets (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id uuid NOT NULL,
  credit_measurement_id uuid NOT NULL REFERENCES henvalt.billing_measurements(id) ON DELETE RESTRICT,
  charge_measurement_id uuid NOT NULL REFERENCES henvalt.billing_measurements(id) ON DELETE RESTRICT,
  amount numeric(18,4) NOT NULL CHECK (amount > 0),
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT billing_measurement_credit_offsets_distinct_measurements
    CHECK (credit_measurement_id <> charge_measurement_id),
  CONSTRAINT billing_measurement_credit_offsets_unique
    UNIQUE (tenant_id, credit_measurement_id, charge_measurement_id)
);

ALTER TABLE henvalt.billing_measurement_credit_offsets ENABLE ROW LEVEL SECURITY;

CREATE INDEX IF NOT EXISTS billing_measurement_credit_offsets_charge_idx
  ON henvalt.billing_measurement_credit_offsets (tenant_id, charge_measurement_id);
CREATE INDEX IF NOT EXISTS billing_measurement_credit_offsets_credit_idx
  ON henvalt.billing_measurement_credit_offsets (tenant_id, credit_measurement_id);

REVOKE ALL ON TABLE henvalt.billing_measurement_credit_offsets FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION henvalt.control_plane_claim_billing_usage(p_shop_domain text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO pg_catalog, henvalt, pg_temp
AS $function$
DECLARE
  v_shop text := lower(btrim(coalesce(p_shop_domain, '')));
  v_tenant_id uuid;
  v_line_item text;
  v_currency char(3);
  v_charge henvalt.billing_usage_charges%ROWTYPE;
  v_measurement henvalt.billing_measurements%ROWTYPE;
  v_credit record;
  v_remaining numeric(18,4);
  v_credit_remaining numeric(18,4);
  v_apply numeric(18,4);
BEGIN
  IF v_shop !~ '^[a-z0-9][a-z0-9-]*[.]myshopify[.]com$' THEN
    RAISE EXCEPTION 'Invalid Shopify shop domain' USING ERRCODE = '22023';
  END IF;

  SELECT sc.tenant_id
    INTO v_tenant_id
    FROM henvalt.shopify_connections sc
    JOIN henvalt.tenants t ON t.id = sc.tenant_id
   WHERE lower(sc.shop_domain) = v_shop
     AND sc.active = true
     AND t.status = 'ACTIVE'
   LIMIT 1;

  IF v_tenant_id IS NULL THEN
    RETURN jsonb_build_object('available', false, 'reason', 'SHOP_NOT_ACTIVE');
  END IF;

  SELECT usage_line_item_id, currency
    INTO v_line_item, v_currency
    FROM henvalt.billing_accounts
   WHERE tenant_id = v_tenant_id
     AND status = 'ACTIVE';

  IF v_line_item IS NULL THEN
    RETURN jsonb_build_object('available', false, 'reason', 'BILLING_SUBSCRIPTION_NOT_ACTIVE');
  END IF;

  -- Lock one positive, confirmed, measured recovery. A pre-existing charge is
  -- retried with its original net amount; credits are never reallocated on retry.
  SELECT bm.*
    INTO v_measurement
    FROM henvalt.billing_measurements bm
    JOIN henvalt.revenue_ledger rl
      ON rl.id = bm.ledger_entry_id
     AND rl.tenant_id = bm.tenant_id
    LEFT JOIN henvalt.billing_usage_charges buc
      ON buc.billing_measurement_id = bm.id
   WHERE bm.tenant_id = v_tenant_id
     AND bm.status = 'MEASURED'
     AND bm.henvalt_fee > 0
     AND bm.currency = v_currency
     AND rl.entry_type = 'RECOVERY'
     AND rl.billable = true
     AND rl.attribution_confidence = 'CONFIRMED'
     AND rl.billing_status = 'MEASURED'
     AND (
       buc.id IS NULL
       OR (buc.status = 'FAILED' AND buc.attempt_count < 5 AND buc.attempted_at < now() - interval '1 minute')
       OR (buc.status = 'PENDING' AND buc.attempt_count < 5 AND buc.attempted_at < now() - interval '2 minutes')
     )
   ORDER BY bm.created_at, bm.id
   LIMIT 1
   FOR UPDATE OF bm SKIP LOCKED;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('available', false, 'reason', 'NO_PENDING_USAGE_CHARGE');
  END IF;

  SELECT *
    INTO v_charge
    FROM henvalt.billing_usage_charges
   WHERE billing_measurement_id = v_measurement.id
   LIMIT 1
   FOR UPDATE;

  IF FOUND THEN
    UPDATE henvalt.billing_usage_charges
       SET status = 'PENDING',
           attempt_count = attempt_count + 1,
           attempted_at = now(),
           error_code = NULL,
           error_message = NULL,
           updated_at = now()
     WHERE id = v_charge.id
     RETURNING * INTO v_charge;

    RETURN jsonb_build_object(
      'available', true,
      'chargeId', v_charge.id,
      'measurementId', v_measurement.id,
      'tenantId', v_tenant_id,
      'shop', v_shop,
      'subscriptionLineItemId', v_line_item,
      'amount', v_charge.amount,
      'currency', v_charge.currency,
      'idempotencyKey', v_charge.idempotency_key,
      'attempt', v_charge.attempt_count
    );
  END IF;

  v_remaining := v_measurement.henvalt_fee;

  -- Allocate each eligible refund/cancellation credit once. Row locks serialize
  -- competing workers so the same credit cannot reduce two charges.
  FOR v_credit IN
    SELECT cbm.id
      FROM henvalt.billing_measurements cbm
      JOIN henvalt.revenue_ledger crl
        ON crl.id = cbm.ledger_entry_id
       AND crl.tenant_id = cbm.tenant_id
     WHERE cbm.tenant_id = v_tenant_id
       AND cbm.currency = v_currency
       AND cbm.status = 'MEASURED'
       AND cbm.henvalt_fee < 0
       AND crl.entry_type = 'ADJUSTMENT'
       AND crl.billable = true
       AND crl.attribution_confidence = 'CONFIRMED'
       AND crl.billing_status = 'MEASURED'
     ORDER BY cbm.created_at, cbm.id
     FOR UPDATE OF cbm
  LOOP
    EXIT WHEN v_remaining <= 0;

    -- Re-read the offset total in a fresh READ COMMITTED statement snapshot
    -- after obtaining the credit-row lock. The cursor snapshot may predate a
    -- competing worker's commit while this loop waited for that lock.
    SELECT abs(cbm.henvalt_fee) - COALESCE(sum(o.amount), 0)
      INTO v_credit_remaining
      FROM henvalt.billing_measurements cbm
      LEFT JOIN henvalt.billing_measurement_credit_offsets o
        ON o.tenant_id = cbm.tenant_id
       AND o.credit_measurement_id = cbm.id
     WHERE cbm.id = v_credit.id
       AND cbm.tenant_id = v_tenant_id
     GROUP BY cbm.henvalt_fee;

    IF COALESCE(v_credit_remaining, 0) <= 0 THEN
      CONTINUE;
    END IF;

    v_apply := LEAST(v_remaining, v_credit_remaining);

    INSERT INTO henvalt.billing_measurement_credit_offsets (
      tenant_id, credit_measurement_id, charge_measurement_id, amount
    ) VALUES (
      v_tenant_id, v_credit.id, v_measurement.id, v_apply
    )
    ON CONFLICT (tenant_id, credit_measurement_id, charge_measurement_id)
    DO NOTHING;

    IF FOUND THEN
      v_remaining := v_remaining - v_apply;
    END IF;
  END LOOP;

  IF v_remaining <= 0 THEN
    UPDATE henvalt.billing_measurements
       SET status = 'VOIDED'
     WHERE id = v_measurement.id
       AND tenant_id = v_tenant_id
       AND status = 'MEASURED';

    UPDATE henvalt.revenue_ledger
       SET billing_status = 'VOIDED'
     WHERE id = v_measurement.ledger_entry_id
       AND tenant_id = v_tenant_id
       AND billing_status = 'MEASURED';

    RETURN jsonb_build_object(
      'available', false,
      'reason', 'FULLY_OFFSET_BY_REFUND_CREDIT',
      'measurementId', v_measurement.id,
      'creditApplied', v_measurement.henvalt_fee
    );
  END IF;

  INSERT INTO henvalt.billing_usage_charges (
    tenant_id, billing_measurement_id, provider, idempotency_key,
    amount, currency, status, attempt_count, attempted_at
  ) VALUES (
    v_tenant_id,
    v_measurement.id,
    'SHOPIFY',
    'henvalt-recovery-' || replace(v_measurement.id::text, '-', ''),
    v_remaining,
    v_measurement.currency,
    'PENDING',
    1,
    now()
  )
  RETURNING * INTO v_charge;

  RETURN jsonb_build_object(
    'available', true,
    'chargeId', v_charge.id,
    'measurementId', v_measurement.id,
    'tenantId', v_tenant_id,
    'shop', v_shop,
    'subscriptionLineItemId', v_line_item,
    'amount', v_charge.amount,
    'currency', v_charge.currency,
    'idempotencyKey', v_charge.idempotency_key,
    'attempt', v_charge.attempt_count,
    'grossFee', v_measurement.henvalt_fee,
    'refundCreditApplied', v_measurement.henvalt_fee - v_remaining
  );
END;
$function$;

REVOKE ALL ON FUNCTION henvalt.control_plane_claim_billing_usage(text)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION henvalt.control_plane_claim_billing_usage(text)
  TO service_role;

COMMENT ON TABLE henvalt.billing_measurement_credit_offsets IS
  'Immutable tenant/currency-scoped allocations of negative refund/cancellation fee measurements against future positive Shopify usage charges.';

COMMIT;

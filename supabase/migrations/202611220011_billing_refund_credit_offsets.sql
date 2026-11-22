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
  v_test_mode boolean;
  v_charge henvalt.billing_usage_charges%ROWTYPE;
  v_measurement henvalt.billing_measurements%ROWTYPE;
  v_credit record;
  v_remaining numeric(18,4);
  v_credit_remaining numeric(18,4);
  v_apply numeric(18,4);
BEGIN
  IF v_shop !~ '^[a-z0-9][a-z0-9-]*[.]myshopify[.]com'
     OR v_shop <> (split_part(v_shop,'.',1) || '.myshopify.com') THEN
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

  SELECT usage_line_item_id, currency, test_mode
    INTO v_line_item, v_currency, v_test_mode
    FROM henvalt.billing_accounts
   WHERE tenant_id = v_tenant_id
     AND status = 'ACTIVE';

  IF v_line_item IS NULL THEN
    RETURN jsonb_build_object('available', false, 'reason', 'BILLING_SUBSCRIPTION_NOT_ACTIVE');
  END IF;

  -- This candidate worker is deliberately locked to Shopify test subscriptions.
  -- Live merchant charges require a separate reviewed migration and cutover.
  IF v_test_mode IS DISTINCT FROM TRUE THEN
    RETURN jsonb_build_object('available', false, 'reason', 'TEST_MODE_REQUIRED');
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
     AND (buc.id IS NULL OR buc.reconciliation_status IN ('NONE','NOT_FOUND_CONFIRMED'))
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
           reconciliation_status = 'NONE',
           reconciliation_required_at = NULL,
           reconciliation_reason = NULL,
           reconciliation_evidence = '{}'::jsonb,
           reconciliation_resolved_at = NULL,
           reconciliation_operator_reference = NULL,
           reconciliation_operator_note = NULL,
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
      'testMode', v_test_mode,
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
    'testMode', v_test_mode,
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


-- Durable state for exhausted ambiguous Shopify outcomes. Keep provider charge
-- status PENDING while reconciliation is unresolved; the separate state prevents
-- the recovery scheduler from mistaking uncertainty for a normal retry.
ALTER TABLE henvalt.billing_usage_charges
  ADD COLUMN reconciliation_status text NOT NULL DEFAULT 'NONE'
    CHECK (reconciliation_status IN ('NONE','REQUIRED','MISMATCH','NOT_FOUND_CONFIRMED','MATCHED')),
  ADD COLUMN reconciliation_required_at timestamptz,
  ADD COLUMN reconciliation_reason text,
  ADD COLUMN reconciliation_evidence jsonb NOT NULL DEFAULT '{}'::jsonb,
  ADD COLUMN reconciliation_resolved_at timestamptz,
  ADD COLUMN reconciliation_operator_reference text,
  ADD COLUMN reconciliation_operator_note text;

CREATE INDEX billing_usage_charges_reconciliation_queue_idx
  ON henvalt.billing_usage_charges (tenant_id, reconciliation_required_at, created_at)
  WHERE reconciliation_status IN ('REQUIRED','MISMATCH');

CREATE UNIQUE INDEX billing_usage_charges_provider_record_unique
  ON henvalt.billing_usage_charges (provider_usage_record_id)
  WHERE provider_usage_record_id IS NOT NULL;

REVOKE ALL ON TABLE henvalt.billing_usage_charges FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION henvalt.control_plane_mark_billing_reconciliation_required(
  p_shop_domain text,
  p_charge_id uuid,
  p_reason text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO pg_catalog, henvalt, pg_temp
AS $function$
DECLARE
  v_shop text := lower(btrim(coalesce(p_shop_domain, '')));
  v_tenant_id uuid;
  v_attempt integer;
  v_status text;
BEGIN
  IF current_setting('request.jwt.claim.role', true) IS DISTINCT FROM 'service_role' THEN
    RAISE EXCEPTION 'Service role required' USING ERRCODE = '42501';
  END IF;
  IF v_shop !~ '^[a-z0-9][a-z0-9-]*[.]myshopify[.]com'
     OR v_shop <> (split_part(v_shop,'.',1) || '.myshopify.com')
     OR p_charge_id IS NULL
     OR p_reason IS NULL
     OR p_reason NOT IN (
       'SHOPIFY_TRANSPORT_OUTCOME_UNKNOWN',
       'SHOPIFY_TRANSIENT_HTTP',
       'SHOPIFY_RESPONSE_NOT_JSON',
       'SHOPIFY_GRAPHQL_OUTCOME_UNKNOWN',
       'SHOPIFY_IDEMPOTENCY_REQUEST_IN_PROGRESS',
       'SHOPIFY_USAGE_RESPONSE_INCOMPLETE',
       'LOCAL_RESULT_COMMIT_UNKNOWN'
     ) THEN
    RAISE EXCEPTION 'Invalid reconciliation request' USING ERRCODE = '22023';
  END IF;

  SELECT buc.tenant_id, buc.attempt_count, buc.reconciliation_status
    INTO v_tenant_id, v_attempt, v_status
    FROM henvalt.billing_usage_charges buc
    JOIN henvalt.shopify_connections sc
      ON sc.tenant_id = buc.tenant_id
     AND lower(sc.shop_domain) = v_shop
     AND sc.active = true
    JOIN henvalt.tenants t
      ON t.id = buc.tenant_id
     AND t.status = 'ACTIVE'
    JOIN henvalt.billing_accounts ba
      ON ba.tenant_id = buc.tenant_id
     AND ba.status = 'ACTIVE'
     AND ba.test_mode = true
   WHERE buc.id = p_charge_id
     AND buc.provider = 'SHOPIFY'
     AND buc.status = 'PENDING'
     AND buc.provider_usage_record_id IS NULL
   FOR UPDATE OF buc;

  IF v_tenant_id IS NULL THEN
    RETURN jsonb_build_object('updated', false, 'reason', 'CHARGE_NOT_ELIGIBLE');
  END IF;
  IF v_attempt < 5 THEN
    RETURN jsonb_build_object('updated', false, 'reason', 'RETRY_BUDGET_NOT_EXHAUSTED');
  END IF;
  IF v_status = 'MATCHED' OR v_status = 'NOT_FOUND_CONFIRMED' THEN
    RETURN jsonb_build_object('updated', false, 'reason', 'RECONCILIATION_ALREADY_RESOLVED');
  END IF;

  UPDATE henvalt.billing_usage_charges
     SET reconciliation_status = 'REQUIRED',
         reconciliation_required_at = COALESCE(reconciliation_required_at, now()),
         reconciliation_reason = p_reason,
         reconciliation_evidence = jsonb_build_object(
           'source', 'billing_worker',
           'attemptCount', v_attempt,
           'recordedAt', now()
         ),
         updated_at = now()
   WHERE id = p_charge_id
     AND tenant_id = v_tenant_id;

  INSERT INTO henvalt.audit_log(
    tenant_id,event_name,entity_type,entity_id,actor_type,actor_reference,payload
  ) VALUES (
    v_tenant_id,'BILLING_RECONCILIATION_REQUIRED','BILLING_USAGE_CHARGE',
    p_charge_id,'SYSTEM','henvalt-shopify-usage-billing',
    jsonb_build_object('reason',p_reason,'attemptCount',v_attempt,'shop',v_shop)
  );

  RETURN jsonb_build_object('updated', true, 'status', 'REQUIRED');
END;
$function$;

CREATE OR REPLACE FUNCTION henvalt.control_plane_list_billing_reconciliations(
  p_shop_domain text,
  p_limit integer DEFAULT 50
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO pg_catalog, henvalt, pg_temp
AS $function$
DECLARE
  v_shop text := lower(btrim(coalesce(p_shop_domain, '')));
  v_cases jsonb;
BEGIN
  IF current_setting('request.jwt.claim.role', true) IS DISTINCT FROM 'service_role' THEN
    RAISE EXCEPTION 'Service role required' USING ERRCODE = '42501';
  END IF;
  IF v_shop !~ '^[a-z0-9][a-z0-9-]*[.]myshopify[.]com'
     OR v_shop <> (split_part(v_shop,'.',1) || '.myshopify.com')
     OR p_limit IS NULL
     OR p_limit < 1
     OR p_limit > 100 THEN
    RAISE EXCEPTION 'Invalid reconciliation list request' USING ERRCODE = '22023';
  END IF;

  SELECT COALESCE(
    jsonb_agg(
      jsonb_build_object(
        'chargeId',q.id,
        'shop',v_shop,
        'status',q.status,
        'reconciliationStatus',q.reconciliation_status,
        'reason',q.reconciliation_reason,
        'amount',q.amount,
        'currency',q.currency,
        'idempotencyKey',q.idempotency_key,
        'subscriptionLineItemId',q.usage_line_item_id,
        'attemptCount',q.attempt_count,
        'requiredAt',q.reconciliation_required_at,
        'attemptedAt',q.attempted_at,
        'evidence',q.reconciliation_evidence
      )
      ORDER BY q.reconciliation_required_at NULLS LAST,q.created_at
    ),
    '[]'::jsonb
  )
    INTO v_cases
    FROM (
      SELECT buc.*,ba.usage_line_item_id
        FROM henvalt.billing_usage_charges buc
        JOIN henvalt.shopify_connections sc
          ON sc.tenant_id = buc.tenant_id
         AND lower(sc.shop_domain) = v_shop
         AND sc.active = true
        JOIN henvalt.tenants t
          ON t.id = buc.tenant_id
         AND t.status = 'ACTIVE'
        JOIN henvalt.billing_accounts ba
          ON ba.tenant_id = buc.tenant_id
         AND ba.status = 'ACTIVE'
         AND ba.test_mode = true
       WHERE buc.provider = 'SHOPIFY'
         AND buc.status = 'PENDING'
         AND buc.reconciliation_status IN ('REQUIRED','MISMATCH')
       ORDER BY buc.reconciliation_required_at NULLS LAST,buc.created_at
       LIMIT p_limit
    ) q;

  RETURN jsonb_build_object(
    'cases',v_cases,
    'count',jsonb_array_length(v_cases),
    'shop',v_shop
  );
END;
$function$;

CREATE OR REPLACE FUNCTION henvalt.control_plane_get_billing_reconciliation(
  p_shop_domain text,
  p_charge_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO pg_catalog, henvalt, pg_temp
AS $function$
DECLARE
  v_shop text := lower(btrim(coalesce(p_shop_domain, '')));
  v_result jsonb;
BEGIN
  IF current_setting('request.jwt.claim.role', true) IS DISTINCT FROM 'service_role' THEN
    RAISE EXCEPTION 'Service role required' USING ERRCODE = '42501';
  END IF;
  IF v_shop !~ '^[a-z0-9][a-z0-9-]*[.]myshopify[.]com'
     OR v_shop <> (split_part(v_shop,'.',1) || '.myshopify.com')
     OR p_charge_id IS NULL THEN
    RAISE EXCEPTION 'Invalid reconciliation lookup' USING ERRCODE = '22023';
  END IF;

  SELECT jsonb_build_object(
    'available',true,
    'chargeId',buc.id,
    'tenantId',buc.tenant_id,
    'shop',v_shop,
    'status',buc.status,
    'reconciliationStatus',buc.reconciliation_status,
    'reason',buc.reconciliation_reason,
    'amount',buc.amount,
    'currency',buc.currency,
    'idempotencyKey',buc.idempotency_key,
    'subscriptionLineItemId',ba.usage_line_item_id,
    'attemptCount',buc.attempt_count,
    'requiredAt',buc.reconciliation_required_at,
    'evidence',buc.reconciliation_evidence,
    'providerUsageRecordId',buc.provider_usage_record_id
  )
    INTO v_result
    FROM henvalt.billing_usage_charges buc
    JOIN henvalt.shopify_connections sc
      ON sc.tenant_id = buc.tenant_id
     AND lower(sc.shop_domain) = v_shop
     AND sc.active = true
    JOIN henvalt.tenants t
      ON t.id = buc.tenant_id
     AND t.status = 'ACTIVE'
    JOIN henvalt.billing_accounts ba
      ON ba.tenant_id = buc.tenant_id
     AND ba.status = 'ACTIVE'
     AND ba.test_mode = true
   WHERE buc.id = p_charge_id
     AND buc.provider = 'SHOPIFY'
     AND buc.reconciliation_status IN ('REQUIRED','MISMATCH')
     AND buc.status = 'PENDING';

  RETURN COALESCE(v_result,jsonb_build_object('available',false,'reason','RECONCILIATION_NOT_FOUND'));
END;
$function$;

CREATE OR REPLACE FUNCTION henvalt.control_plane_resolve_billing_reconciliation(
  p_shop_domain text,
  p_charge_id uuid,
  p_resolution text,
  p_provider_usage_record_id text,
  p_evidence jsonb,
  p_operator_reference text,
  p_operator_note text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO pg_catalog, henvalt, pg_temp
AS $function$
DECLARE
  v_shop text := lower(btrim(coalesce(p_shop_domain, '')));
  v_charge henvalt.billing_usage_charges%ROWTYPE;
  v_line_item text;
  v_ledger_entry_id uuid;
  v_new_status text;
  v_safe_evidence jsonb;
BEGIN
  IF current_setting('request.jwt.claim.role', true) IS DISTINCT FROM 'service_role' THEN
    RAISE EXCEPTION 'Service role required' USING ERRCODE = '42501';
  END IF;
  IF v_shop !~ '^[a-z0-9][a-z0-9-]*[.]myshopify[.]com'
     OR v_shop <> (split_part(v_shop,'.',1) || '.myshopify.com')
     OR p_charge_id IS NULL
     OR p_resolution IS NULL
     OR p_resolution NOT IN ('MATCHED','NOT_FOUND_CONFIRMED','MISMATCH')
     OR jsonb_typeof(COALESCE(p_evidence,'{}'::jsonb)) <> 'object'
     OR octet_length(COALESCE(p_evidence,'{}'::jsonb)::text) > 16384
     OR length(btrim(COALESCE(p_operator_reference,''))) NOT BETWEEN 1 AND 128
     OR length(btrim(COALESCE(p_operator_note,''))) NOT BETWEEN 1 AND 1000 THEN
    RAISE EXCEPTION 'Invalid reconciliation resolution' USING ERRCODE = '22023';
  END IF;

  SELECT buc.*
    INTO v_charge
    FROM henvalt.billing_usage_charges buc
    JOIN henvalt.shopify_connections sc
      ON sc.tenant_id = buc.tenant_id
     AND lower(sc.shop_domain) = v_shop
     AND sc.active = true
    JOIN henvalt.tenants t
      ON t.id = buc.tenant_id
     AND t.status = 'ACTIVE'
    JOIN henvalt.billing_accounts ba
      ON ba.tenant_id = buc.tenant_id
     AND ba.status = 'ACTIVE'
     AND ba.test_mode = true
   WHERE buc.id = p_charge_id
     AND buc.provider = 'SHOPIFY'
     AND buc.status = 'PENDING'
     AND buc.reconciliation_status IN ('REQUIRED','MISMATCH')
   FOR UPDATE OF buc;

  IF v_charge.id IS NULL THEN
    RETURN jsonb_build_object('updated',false,'reason','CHARGE_NOT_ELIGIBLE');
  END IF;

  -- Persist only the allowlisted provider evidence fields, never arbitrary request keys.
  v_safe_evidence := jsonb_build_object(
    'lookupComplete',p_evidence->'lookupComplete',
    'subscriptionFound',p_evidence->'subscriptionFound',
    'lineItemFound',p_evidence->'lineItemFound',
    'providerUsageRecordId',p_evidence->'providerUsageRecordId',
    'matchingCount',p_evidence->'matchingCount',
    'idempotencyKey',p_evidence->'idempotencyKey',
    'lineItemId',p_evidence->'lineItemId',
    'amount',p_evidence->'amount',
    'currency',p_evidence->'currency',
    'pagesScanned',p_evidence->'pagesScanned'
  );

  SELECT usage_line_item_id
    INTO v_line_item
    FROM henvalt.billing_accounts
   WHERE tenant_id = v_charge.tenant_id
     AND status = 'ACTIVE'
     AND test_mode = true;

  IF p_resolution = 'MATCHED' THEN
    IF left(COALESCE(p_provider_usage_record_id,''),length('gid://shopify/AppUsageRecord/')) <> 'gid://shopify/AppUsageRecord/'
       OR substring(COALESCE(p_provider_usage_record_id,'') from length('gid://shopify/AppUsageRecord/')+1) = ''
       OR translate(substring(COALESCE(p_provider_usage_record_id,'') from length('gid://shopify/AppUsageRecord/')+1),'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-','') <> ''
       OR p_evidence->>'lookupComplete' IS DISTINCT FROM 'true'
       OR p_evidence->>'subscriptionFound' IS DISTINCT FROM 'true'
       OR p_evidence->>'lineItemFound' IS DISTINCT FROM 'true'
       OR p_evidence->>'providerUsageRecordId' IS DISTINCT FROM p_provider_usage_record_id
       OR p_evidence->>'matchingCount' IS DISTINCT FROM '1'
       OR p_evidence->>'idempotencyKey' IS DISTINCT FROM v_charge.idempotency_key
       OR p_evidence->>'lineItemId' IS DISTINCT FROM v_line_item
       OR p_evidence->>'currency' IS DISTINCT FROM v_charge.currency::text
       OR CASE
            WHEN COALESCE(p_evidence->>'amount','') <> ''
             AND translate(COALESCE(p_evidence->>'amount',''),'0123456789.','') = ''
             AND replace(COALESCE(p_evidence->>'amount',''),'.','') <> ''
             AND length(COALESCE(p_evidence->>'amount','')) - length(replace(COALESCE(p_evidence->>'amount',''),'.','')) <= 1
             AND length(split_part(COALESCE(p_evidence->>'amount',''),'.',2)) <= 4
            THEN (p_evidence->>'amount')::numeric <> v_charge.amount
            ELSE true
          END THEN
      RAISE EXCEPTION 'Provider evidence does not match the persisted charge envelope' USING ERRCODE = '22023';
    END IF;

    UPDATE henvalt.billing_usage_charges
       SET status = 'SUBMITTED',
           provider_usage_record_id = p_provider_usage_record_id,
           submitted_at = COALESCE(submitted_at,now()),
           reconciliation_status = 'MATCHED',
           reconciliation_evidence = v_safe_evidence,
           reconciliation_resolved_at = now(),
           reconciliation_operator_reference = btrim(p_operator_reference),
           reconciliation_operator_note = btrim(p_operator_note),
           updated_at = now()
     WHERE id = v_charge.id
       AND tenant_id = v_charge.tenant_id;

    SELECT ledger_entry_id INTO v_ledger_entry_id
      FROM henvalt.billing_measurements
     WHERE id = v_charge.billing_measurement_id
       AND tenant_id = v_charge.tenant_id;

    UPDATE henvalt.billing_measurements
       SET status = 'BILLED'
     WHERE id = v_charge.billing_measurement_id
       AND tenant_id = v_charge.tenant_id
       AND status = 'MEASURED';

    UPDATE henvalt.revenue_ledger
       SET billing_status = 'BILLED'
     WHERE id = v_ledger_entry_id
       AND tenant_id = v_charge.tenant_id
       AND billing_status = 'MEASURED';

    v_new_status := 'SUBMITTED';
  ELSIF p_resolution = 'NOT_FOUND_CONFIRMED' THEN
    IF p_evidence->>'lookupComplete' IS DISTINCT FROM 'true'
       OR p_evidence->>'subscriptionFound' IS DISTINCT FROM 'true'
       OR p_evidence->>'lineItemFound' IS DISTINCT FROM 'true'
       OR p_evidence->>'matchingCount' IS DISTINCT FROM '0'
       OR CASE
            WHEN COALESCE(p_evidence->>'pagesScanned','') <> ''
             AND translate(COALESCE(p_evidence->>'pagesScanned',''),'0123456789','') = ''
            THEN (p_evidence->>'pagesScanned')::numeric < 1
            ELSE true
          END THEN
      RAISE EXCEPTION 'Complete no-match provider lookup evidence is required' USING ERRCODE = '22023';
    END IF;

    -- A controlled retry is permitted only after complete no-match evidence.
    -- The immutable idempotency key and original net amount are not changed.
    UPDATE henvalt.billing_usage_charges
       SET status = 'FAILED',
           attempt_count = 0,
           attempted_at = now() - interval '2 minutes',
           reconciliation_status = 'NOT_FOUND_CONFIRMED',
           reconciliation_evidence = v_safe_evidence,
           reconciliation_resolved_at = now(),
           reconciliation_operator_reference = btrim(p_operator_reference),
           reconciliation_operator_note = btrim(p_operator_note),
           updated_at = now()
     WHERE id = v_charge.id
       AND tenant_id = v_charge.tenant_id;

    v_new_status := 'FAILED_RETRY_ALLOWED';
  ELSE
    UPDATE henvalt.billing_usage_charges
       SET reconciliation_status = 'MISMATCH',
           reconciliation_evidence = v_safe_evidence,
           reconciliation_resolved_at = NULL,
           reconciliation_operator_reference = btrim(p_operator_reference),
           reconciliation_operator_note = btrim(p_operator_note),
           updated_at = now()
     WHERE id = v_charge.id
       AND tenant_id = v_charge.tenant_id;

    v_new_status := 'MISMATCH_REQUIRES_REVIEW';
  END IF;

  INSERT INTO henvalt.audit_log(
    tenant_id,event_name,entity_type,entity_id,actor_type,actor_reference,payload
  ) VALUES (
    v_charge.tenant_id,'BILLING_RECONCILIATION_RESOLVED','BILLING_USAGE_CHARGE',
    v_charge.id,'OPERATOR',btrim(p_operator_reference),
    jsonb_build_object(
      'resolution',p_resolution,
      'operatorNote',btrim(p_operator_note),
      'providerUsageRecordId',CASE WHEN p_resolution='MATCHED' THEN p_provider_usage_record_id ELSE NULL END,
      'evidence',v_safe_evidence
    )
  );

  RETURN jsonb_build_object(
    'updated',true,
    'status',v_new_status,
    'chargeId',v_charge.id,
    'idempotencyKey',v_charge.idempotency_key
  );
END;
$function$;

REVOKE ALL ON FUNCTION henvalt.control_plane_mark_billing_reconciliation_required(text,uuid,text)
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION henvalt.control_plane_list_billing_reconciliations(text,integer)
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION henvalt.control_plane_get_billing_reconciliation(text,uuid)
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION henvalt.control_plane_resolve_billing_reconciliation(text,uuid,text,text,jsonb,text,text)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION henvalt.control_plane_mark_billing_reconciliation_required(text,uuid,text)
  TO service_role;
GRANT EXECUTE ON FUNCTION henvalt.control_plane_list_billing_reconciliations(text,integer)
  TO service_role;
GRANT EXECUTE ON FUNCTION henvalt.control_plane_get_billing_reconciliation(text,uuid)
  TO service_role;
GRANT EXECUTE ON FUNCTION henvalt.control_plane_resolve_billing_reconciliation(text,uuid,text,text,jsonb,text,text)
  TO service_role;

COMMENT ON COLUMN henvalt.billing_usage_charges.reconciliation_status IS
  'Durable reconciliation gate for ambiguous Shopify usage-record outcomes; unresolved charges remain PENDING and cannot be automatically retried.';

COMMENT ON TABLE henvalt.billing_measurement_credit_offsets IS
  'Immutable tenant/currency-scoped allocations of negative refund/cancellation fee measurements against future positive Shopify usage charges.';

COMMIT;

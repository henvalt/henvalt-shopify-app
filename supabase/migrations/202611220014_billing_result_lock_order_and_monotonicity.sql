-- Keep billing result commits monotonic and serialize result/reconciliation row locks.
-- This follows the refund-credit migration and only replaces the billing RPCs.
BEGIN;

CREATE OR REPLACE FUNCTION henvalt.control_plane_record_billing_usage_result(
  p_shop_domain text,
  p_charge_id uuid,
  p_success boolean,
  p_provider_usage_record_id text DEFAULT NULL::text,
  p_error_code text DEFAULT NULL::text,
  p_error_message text DEFAULT NULL::text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO pg_catalog, henvalt, pg_temp
AS $function$
DECLARE
  v_shop text := lower(btrim(coalesce(p_shop_domain, '')));
  v_tenant_id uuid;
  v_measurement_id uuid;
  v_existing_status text;
  v_existing_provider_record_id text;
  v_existing_reconciliation_status text;
  v_idempotency_key text;
  v_status text;
BEGIN
  IF current_setting('request.jwt.claim.role', true) IS DISTINCT FROM 'service_role' THEN
    RAISE EXCEPTION 'Service role required' USING ERRCODE = '42501';
  END IF;
  IF v_shop !~ '^[a-z0-9][a-z0-9-]*[.]myshopify[.]com$'
     OR p_charge_id IS NULL
     OR p_success IS NULL THEN
    RAISE EXCEPTION 'Invalid billing result request' USING ERRCODE = '22023';
  END IF;
  IF p_success IS TRUE
     AND (p_provider_usage_record_id IS NULL
       OR length(p_provider_usage_record_id) > 255
       OR p_provider_usage_record_id !~ '^gid://shopify/AppUsageRecord/[A-Za-z0-9_-]+$') THEN
    RAISE EXCEPTION 'Valid Shopify usage record ID is required for success' USING ERRCODE = '22023';
  END IF;

  SELECT tenant_id INTO v_tenant_id
    FROM henvalt.shopify_connections
   WHERE lower(shop_domain) = v_shop
   LIMIT 1;
  IF v_tenant_id IS NULL THEN
    RETURN jsonb_build_object('updated', false, 'reason', 'SHOP_CONNECTION_NOT_FOUND');
  END IF;

  SELECT billing_measurement_id, idempotency_key
    INTO v_measurement_id, v_idempotency_key
    FROM henvalt.billing_usage_charges
   WHERE id = p_charge_id
     AND tenant_id = v_tenant_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('updated', false, 'reason', 'CHARGE_NOT_FOUND');
  END IF;

  -- Lock the measurement before the charge, matching the claim and resolve RPCs.
  PERFORM 1
    FROM henvalt.billing_measurements
   WHERE id = v_measurement_id
     AND tenant_id = v_tenant_id
   FOR UPDATE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('updated', false, 'reason', 'MEASUREMENT_NOT_FOUND');
  END IF;

  SELECT status, provider_usage_record_id, reconciliation_status
    INTO v_existing_status, v_existing_provider_record_id, v_existing_reconciliation_status
    FROM henvalt.billing_usage_charges
   WHERE id = p_charge_id
     AND tenant_id = v_tenant_id
   FOR UPDATE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('updated', false, 'reason', 'CHARGE_NOT_FOUND');
  END IF;

  IF v_existing_reconciliation_status = 'MISMATCH' THEN
    RETURN jsonb_build_object('updated',false,'reason','MISMATCH_REQUIRES_OPERATOR');
  END IF;

  IF v_existing_status = 'SUBMITTED' THEN
    IF p_success IS TRUE AND v_existing_provider_record_id = p_provider_usage_record_id THEN
      IF v_existing_reconciliation_status IN ('REQUIRED','NOT_FOUND_CONFIRMED') THEN
        UPDATE henvalt.billing_usage_charges
           SET reconciliation_status = 'MATCHED',
               reconciliation_resolved_at = now(),
               reconciliation_evidence = jsonb_build_object(
                 'source','billing_worker_result',
                 'providerUsageRecordId',p_provider_usage_record_id,
                 'idempotencyKey',v_idempotency_key,
                 'recordedAt',now()
               ),
               updated_at = now()
         WHERE id = p_charge_id
           AND tenant_id = v_tenant_id;

        INSERT INTO henvalt.audit_log(
          tenant_id,event_name,entity_type,entity_id,actor_type,actor_reference,payload
        ) VALUES (
          v_tenant_id,'BILLING_RECONCILIATION_RESOLVED','BILLING_USAGE_CHARGE',
          p_charge_id,'SYSTEM','henvalt-shopify-usage-billing',
          jsonb_build_object('resolution','MATCHED','source','late_worker_success','providerUsageRecordId',p_provider_usage_record_id)
        );
      END IF;
      RETURN jsonb_build_object('updated',true,'status','SUBMITTED','measurement_id',v_measurement_id,'idempotent',true);
    END IF;
    RETURN jsonb_build_object('updated',false,'reason','CHARGE_ALREADY_SUBMITTED');
  END IF;

  IF v_existing_reconciliation_status = 'REQUIRED' AND p_success IS NOT TRUE THEN
    RETURN jsonb_build_object('updated',false,'reason','RECONCILIATION_REQUIRED');
  END IF;
  IF v_existing_status NOT IN ('PENDING','FAILED') THEN
    RETURN jsonb_build_object('updated',false,'reason','CHARGE_NOT_SETTLEABLE');
  END IF;

  v_status := CASE WHEN p_success THEN 'SUBMITTED' ELSE 'FAILED' END;
  UPDATE henvalt.billing_usage_charges
     SET status = v_status,
         provider_usage_record_id = CASE WHEN p_success THEN p_provider_usage_record_id ELSE provider_usage_record_id END,
         error_code = CASE WHEN p_success THEN NULL ELSE left(coalesce(p_error_code, 'SHOPIFY_USAGE_CHARGE_FAILED'), 128) END,
         error_message = CASE WHEN p_success THEN NULL ELSE left(coalesce(p_error_message, 'Usage charge failed'), 1000) END,
         submitted_at = CASE WHEN p_success THEN coalesce(submitted_at, now()) ELSE submitted_at END,
         reconciliation_status = CASE
           WHEN p_success AND v_existing_reconciliation_status IN ('REQUIRED','NOT_FOUND_CONFIRMED') THEN 'MATCHED'
           ELSE reconciliation_status
         END,
         reconciliation_resolved_at = CASE
           WHEN p_success AND v_existing_reconciliation_status IN ('REQUIRED','NOT_FOUND_CONFIRMED') THEN now()
           ELSE reconciliation_resolved_at
         END,
         reconciliation_evidence = CASE
           WHEN p_success AND v_existing_reconciliation_status IN ('REQUIRED','NOT_FOUND_CONFIRMED') THEN jsonb_build_object(
             'source','billing_worker_result',
             'providerUsageRecordId',p_provider_usage_record_id,
             'idempotencyKey',v_idempotency_key,
             'recordedAt',now()
           )
           ELSE reconciliation_evidence
         END,
         updated_at = now()
   WHERE id = p_charge_id
     AND tenant_id = v_tenant_id;

  IF p_success THEN
    UPDATE henvalt.billing_measurements
       SET status = 'BILLED'
     WHERE id = v_measurement_id
       AND tenant_id = v_tenant_id
       AND status = 'MEASURED';
    UPDATE henvalt.revenue_ledger rl
       SET billing_status = 'BILLED'
      WHERE rl.id = (
        SELECT bm.ledger_entry_id
          FROM henvalt.billing_measurements bm
         WHERE bm.id = v_measurement_id
           AND bm.tenant_id = v_tenant_id
      )
        AND rl.tenant_id = v_tenant_id;

    IF v_existing_reconciliation_status IN ('REQUIRED','NOT_FOUND_CONFIRMED') THEN
      INSERT INTO henvalt.audit_log(
        tenant_id,event_name,entity_type,entity_id,actor_type,actor_reference,payload
      ) VALUES (
        v_tenant_id,'BILLING_RECONCILIATION_RESOLVED','BILLING_USAGE_CHARGE',
        p_charge_id,'SYSTEM','henvalt-shopify-usage-billing',
        jsonb_build_object('resolution','MATCHED','source','late_worker_success','providerUsageRecordId',p_provider_usage_record_id)
      );
    END IF;
  END IF;

  RETURN jsonb_build_object('updated',true,'status',v_status,'measurement_id',v_measurement_id);
END;
$function$;

REVOKE ALL ON FUNCTION henvalt.control_plane_record_billing_usage_result(text,uuid,boolean,text,text,text)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION henvalt.control_plane_record_billing_usage_result(text,uuid,boolean,text,text,text)
  TO service_role;

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
  v_measurement_id uuid;
  v_line_item text;
  v_ledger_entry_id uuid;
  v_new_status text;
  v_safe_evidence jsonb;
  v_amount_matches boolean := false;
  v_pages_scanned numeric;
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

  -- Read the measurement identity first, then lock measurement -> charge.
  -- This matches claim and worker-result commits, preventing a charge/measurement
  -- lock inversion when a late provider response races operator reconciliation.
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
     AND buc.reconciliation_status IN ('REQUIRED','MISMATCH');

  IF v_charge.id IS NULL THEN
    RETURN jsonb_build_object('updated',false,'reason','CHARGE_NOT_ELIGIBLE');
  END IF;

  v_measurement_id := v_charge.billing_measurement_id;
  PERFORM 1
    FROM henvalt.billing_measurements
   WHERE id = v_measurement_id
     AND tenant_id = v_charge.tenant_id
   FOR UPDATE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('updated',false,'reason','MEASUREMENT_NOT_FOUND');
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

  IF COALESCE(p_evidence->>'amount','') <> ''
     AND translate(COALESCE(p_evidence->>'amount',''),'0123456789.','') = ''
     AND replace(COALESCE(p_evidence->>'amount',''),'.','') <> ''
     AND length(COALESCE(p_evidence->>'amount','')) - length(replace(COALESCE(p_evidence->>'amount',''),'.','')) <= 1
     AND length(split_part(COALESCE(p_evidence->>'amount',''),'.',2)) <= 4 THEN
    v_amount_matches := (p_evidence->>'amount')::numeric = v_charge.amount;
  END IF;

  IF COALESCE(p_evidence->>'pagesScanned','') <> ''
     AND translate(COALESCE(p_evidence->>'pagesScanned',''),'0123456789','') = '' THEN
    v_pages_scanned := (p_evidence->>'pagesScanned')::numeric;
  END IF;

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
       OR v_amount_matches IS DISTINCT FROM true THEN
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
       OR v_pages_scanned IS NULL
       OR v_pages_scanned < 1 THEN
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

REVOKE ALL ON FUNCTION henvalt.control_plane_resolve_billing_reconciliation(text,uuid,text,text,jsonb,text,text)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION henvalt.control_plane_resolve_billing_reconciliation(text,uuid,text,text,jsonb,text,text)
  TO service_role;

COMMIT;

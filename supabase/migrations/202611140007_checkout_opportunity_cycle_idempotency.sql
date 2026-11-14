-- Prevent a closed legacy checkout opportunity from shadowing a newer
-- abandonment cycle already created by process_abandoned_checkout_candidates.
-- The recovery worker remains responsible for creating new cycles after inactivity.
CREATE OR REPLACE FUNCTION henvalt.create_opportunity_idempotent(
  p_tenant_id uuid,
  p_source_event_id uuid,
  p_customer_id uuid,
  p_checkout_id uuid,
  p_opportunity_type henvalt.opportunity_type,
  p_value_at_risk numeric,
  p_currency character,
  p_confidence_score numeric,
  p_idempotency_key text,
  p_expires_at timestamp with time zone DEFAULT NULL::timestamp with time zone,
  p_correlation_id uuid DEFAULT NULL::uuid
)
RETURNS TABLE(opportunity_id uuid, is_duplicate boolean)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'henvalt', 'public', 'pg_temp'
AS $function$
DECLARE
  v_existing henvalt.opportunities%ROWTYPE;
  v_active_cycle_id uuid;
  v_customer_exists boolean;
  v_checkout_exists boolean;
  v_has_delivery boolean;
  v_has_sent_intervention boolean;
  v_correlation uuid;
BEGIN
  IF p_tenant_id IS NULL OR p_customer_id IS NULL OR p_checkout_id IS NULL
     OR p_idempotency_key IS NULL OR btrim(p_idempotency_key)='' THEN
    RAISE EXCEPTION 'Tenant, customer, checkout and idempotency key are required';
  END IF;
  PERFORM pg_advisory_xact_lock(hashtextextended(p_tenant_id::text || ':' || p_idempotency_key,0));
  SELECT EXISTS(SELECT 1 FROM henvalt.customers c WHERE c.id=p_customer_id AND c.tenant_id=p_tenant_id) INTO v_customer_exists;
  IF NOT v_customer_exists THEN RAISE EXCEPTION 'Customer does not belong to tenant'; END IF;
  SELECT EXISTS(SELECT 1 FROM henvalt.checkouts ck WHERE ck.id=p_checkout_id AND ck.tenant_id=p_tenant_id) INTO v_checkout_exists;
  IF NOT v_checkout_exists THEN RAISE EXCEPTION 'Checkout does not belong to tenant'; END IF;

  SELECT * INTO v_existing FROM henvalt.opportunities o
   WHERE o.tenant_id=p_tenant_id AND o.idempotency_key=p_idempotency_key FOR UPDATE;

  IF FOUND THEN
    IF v_existing.checkout_id IS DISTINCT FROM p_checkout_id THEN
      RAISE EXCEPTION 'Idempotency identity conflict: checkout changed for existing opportunity %',v_existing.id;
    END IF;

    -- A closed legacy checkout opportunity must not absorb a later abandonment cycle.
    -- If the recovery worker has already created the current cycle, return that cycle
    -- instead of the historical opportunity. The worker remains the sole creator of
    -- new cycles after the inactivity window.
    IF v_existing.opportunity_type='ABANDONED_CHECKOUT'
       AND v_existing.status IN ('CLOSED','SUPPRESSED','RECOVERED','EXPIRED') THEN
      SELECT o.id INTO v_active_cycle_id
      FROM henvalt.opportunities o
      WHERE o.tenant_id=p_tenant_id
        AND o.checkout_id=p_checkout_id
        AND o.opportunity_type='ABANDONED_CHECKOUT'
        AND o.status IN ('DETECTED','ELIGIBLE')
        AND o.idempotency_key LIKE 'checkout-cycle:%'
        AND NOT EXISTS (
          SELECT 1 FROM henvalt.recovery_sequences rs
          WHERE rs.tenant_id=o.tenant_id AND rs.opportunity_id=o.id
        )
        AND NOT EXISTS (
          SELECT 1 FROM henvalt.recovery_interventions ri
          WHERE ri.tenant_id=o.tenant_id AND ri.opportunity_id=o.id
        )
      ORDER BY o.updated_at DESC,o.created_at DESC
      LIMIT 1
      FOR UPDATE;

      IF v_active_cycle_id IS NOT NULL THEN
        opportunity_id:=v_active_cycle_id;
        is_duplicate:=true;
        RETURN NEXT;
        RETURN;
      END IF;
    END IF;

    SELECT EXISTS(SELECT 1 FROM henvalt.delivery_requests dr
      WHERE dr.tenant_id=p_tenant_id AND dr.opportunity_id=v_existing.id) INTO v_has_delivery;
    SELECT EXISTS(SELECT 1 FROM henvalt.recovery_interventions ri
      WHERE ri.tenant_id=p_tenant_id AND ri.opportunity_id=v_existing.id
      AND (ri.sent_at IS NOT NULL OR ri.delivered_at IS NOT NULL OR ri.status IN ('SENDING','SENT','DELIVERED')))
      INTO v_has_sent_intervention;
    IF v_has_delivery OR v_has_sent_intervention THEN
      IF v_existing.customer_id IS DISTINCT FROM p_customer_id THEN
        RAISE EXCEPTION 'Recipient identity conflict: opportunity % has delivery history; manual review required',v_existing.id;
      END IF;
      opportunity_id:=v_existing.id; is_duplicate:=true; RETURN NEXT; RETURN;
    END IF;
    UPDATE henvalt.opportunities o
       SET customer_id=p_customer_id,
           value_at_risk=COALESCE(p_value_at_risk,o.value_at_risk),
           currency=COALESCE(p_currency,o.currency),
           confidence_score=COALESCE(p_confidence_score,o.confidence_score),
           expires_at=COALESCE(p_expires_at,o.expires_at),
           correlation_id=COALESCE(p_correlation_id,o.correlation_id),
           updated_at=now()
     WHERE o.id=v_existing.id AND o.tenant_id=p_tenant_id;
    opportunity_id:=v_existing.id; is_duplicate:=true; RETURN NEXT; RETURN;
  END IF;

  v_correlation:=COALESCE(p_correlation_id,gen_random_uuid());
  INSERT INTO henvalt.opportunities(
    tenant_id,customer_id,checkout_id,source_event_id,opportunity_type,status,
    value_at_risk,currency,confidence_score,idempotency_key,correlation_id,expires_at
  ) VALUES (
    p_tenant_id,p_customer_id,p_checkout_id,p_source_event_id,p_opportunity_type,'DETECTED',
    p_value_at_risk,p_currency,p_confidence_score,p_idempotency_key,v_correlation,p_expires_at
  ) RETURNING id INTO opportunity_id;
  is_duplicate:=false; RETURN NEXT;
END;
$function$;

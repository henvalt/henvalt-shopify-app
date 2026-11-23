-- Durable, one-way provider-egress fence for immutable delivery generations.
-- Depends on 202611230002_delivery_generation_schema_and_retry_rpc.sql and
-- the provider-send interlock contract from 202611210001_provider_send_interlock_v1.sql.
-- Candidate only; do not apply to production.

BEGIN;

DO $guard$
BEGIN
  IF to_regclass('henvalt.provider_send_control') IS NULL
     OR to_regprocedure('henvalt.assert_provider_sending_enabled()') IS NULL
     OR to_regclass('henvalt.delivery_requests') IS NULL
     OR to_regclass('henvalt.recovery_interventions') IS NULL THEN
    RAISE EXCEPTION 'DELIVERY_EGRESS_FENCE_PREREQUISITES_MISSING';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
     WHERE table_schema='henvalt' AND table_name='delivery_requests'
       AND column_name='provider_egress_started_at'
  ) THEN
    RAISE EXCEPTION 'DELIVERY_EGRESS_MARKER_COLUMN_MISSING';
  END IF;
END;
$guard$;

CREATE OR REPLACE FUNCTION henvalt.mark_mailersend_provider_egress_started(
  p_tenant_id uuid,
  p_delivery_request_id uuid
) RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO pg_catalog, henvalt, auth, pg_temp
AS $function$
DECLARE
  v_intervention_id uuid;
  v_intervention henvalt.recovery_interventions%ROWTYPE;
  v_request henvalt.delivery_requests%ROWTYPE;
BEGIN
  IF auth.role() IS DISTINCT FROM 'service_role' THEN
    RAISE EXCEPTION 'SERVICE_ROLE_REQUIRED' USING ERRCODE='42501';
  END IF;
  IF p_tenant_id IS NULL OR p_delivery_request_id IS NULL THEN
    RAISE EXCEPTION 'DELIVERY_EGRESS_IDENTITY_REQUIRED' USING ERRCODE='22023';
  END IF;

  -- Resolve the parent without locking the child. Every lifecycle writer then
  -- takes the canonical parent -> request lock order.
  SELECT dr.intervention_id INTO v_intervention_id
    FROM henvalt.delivery_requests dr
   WHERE dr.id=p_delivery_request_id AND dr.tenant_id=p_tenant_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'DELIVERY_REQUEST_NOT_FOUND'; END IF;

  SELECT * INTO v_intervention
    FROM henvalt.recovery_interventions ri
   WHERE ri.id=v_intervention_id AND ri.tenant_id=p_tenant_id
   FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'DELIVERY_INTERVENTION_NOT_FOUND'; END IF;

  SELECT * INTO v_request
    FROM henvalt.delivery_requests dr
   WHERE dr.id=p_delivery_request_id AND dr.tenant_id=p_tenant_id
   FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'DELIVERY_REQUEST_NOT_FOUND'; END IF;

  IF v_intervention.status <> 'SENDING'
     OR v_intervention.delivery_frozen_at IS NOT NULL THEN
    RAISE EXCEPTION 'DELIVERY_INTERVENTION_NOT_SENDABLE';
  END IF;
  IF v_request.status <> 'UNKNOWN'
     OR v_request.provider_claimed_at IS NULL
     OR v_request.channel <> 'EMAIL'
     OR lower(COALESCE(v_request.provider,'')) <> 'mailersend' THEN
    RAISE EXCEPTION 'DELIVERY_REQUEST_NOT_EGRESS_READY';
  END IF;
  IF EXISTS (
    SELECT 1 FROM henvalt.delivery_requests newer
     WHERE newer.tenant_id=p_tenant_id
       AND newer.intervention_id=v_intervention_id
       AND newer.generation_number > v_request.generation_number
  ) THEN
    RAISE EXCEPTION 'STALE_DELIVERY_GENERATION';
  END IF;
  IF v_request.provider_egress_started_at IS NOT NULL THEN
    RAISE EXCEPTION 'DELIVERY_PROVIDER_EGRESS_ALREADY_STARTED';
  END IF;

  -- Recheck the global default-deny interlock after all row locks and as close
  -- as possible to the HTTP request. This shares the control-row lock with the
  -- operator setter, so closing the gate serializes with this boundary.
  PERFORM henvalt.assert_provider_sending_enabled();

  UPDATE henvalt.delivery_requests
     SET provider_egress_started_at=clock_timestamp(),
         updated_at=clock_timestamp()
   WHERE id=p_delivery_request_id
     AND tenant_id=p_tenant_id
     AND status='UNKNOWN'
     AND provider_claimed_at IS NOT NULL
     AND provider_egress_started_at IS NULL;
  IF NOT FOUND THEN RAISE EXCEPTION 'DELIVERY_EGRESS_COMPARE_AND_SET_LOST'; END IF;

  RETURN true;
END;
$function$;

REVOKE ALL ON FUNCTION henvalt.mark_mailersend_provider_egress_started(uuid,uuid)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION henvalt.mark_mailersend_provider_egress_started(uuid,uuid)
  TO service_role;

COMMENT ON FUNCTION henvalt.mark_mailersend_provider_egress_started(uuid,uuid) IS
  'One-way service-role compare-and-set fence. Must commit immediately before MailerSend HTTP egress; any marker means outcome is non-retryable.';

COMMIT;

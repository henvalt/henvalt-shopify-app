-- Immutable delivery generations: additive production-shaped candidate.
-- Depends on 202611230001_email_usage_reservations.sql.
-- DO NOT APPLY TO PRODUCTION: authorization, claim, result and webhook RPCs
-- still require coordinated parent-first rewrites before this migration is deployable.
BEGIN;

DO $guard$
DECLARE
  v_index_def text;
BEGIN
  IF to_regclass('henvalt.delivery_requests') IS NULL
     OR to_regclass('henvalt.recovery_interventions') IS NULL
     OR to_regclass('henvalt.delivery_attempts') IS NULL
     OR to_regclass('henvalt.email_usage_reservations') IS NULL
     OR to_regclass('henvalt.email_usage_reservation_events') IS NULL THEN
    RAISE EXCEPTION 'DELIVERY_GENERATION_PREREQUISITES_MISSING';
  END IF;

  SELECT pg_get_indexdef('henvalt.ux_delivery_request_intervention'::regclass)
    INTO v_index_def;
  IF v_index_def IS NULL
     OR v_index_def NOT ILIKE '%UNIQUE INDEX%'
     OR v_index_def NOT ILIKE '%(tenant_id, intervention_id)%' THEN
    RAISE EXCEPTION 'DELIVERY_GENERATION_UNEXPECTED_INTERVENTION_INDEX: %', v_index_def;
  END IF;
END;
$guard$;

ALTER TABLE henvalt.delivery_requests
  ADD COLUMN IF NOT EXISTS generation_number integer NOT NULL DEFAULT 1,
  ADD COLUMN IF NOT EXISTS provider_egress_started_at timestamptz;

ALTER TABLE henvalt.recovery_interventions
  ADD COLUMN IF NOT EXISTS delivery_frozen_at timestamptz,
  ADD COLUMN IF NOT EXISTS delivery_freeze_reason text;

DO $constraints$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conrelid='henvalt.delivery_requests'::regclass
      AND conname='delivery_requests_generation_number_positive'
  ) THEN
    ALTER TABLE henvalt.delivery_requests
      ADD CONSTRAINT delivery_requests_generation_number_positive
      CHECK (generation_number > 0) NOT VALID;
  END IF;
END;
$constraints$;

ALTER TABLE henvalt.delivery_requests
  VALIDATE CONSTRAINT delivery_requests_generation_number_positive;

DROP INDEX henvalt.ux_delivery_request_intervention;
CREATE UNIQUE INDEX ux_delivery_request_intervention_generation
  ON henvalt.delivery_requests (tenant_id, intervention_id, generation_number);

CREATE TABLE IF NOT EXISTS henvalt.delivery_retry_commands (
  tenant_id uuid NOT NULL,
  intervention_id uuid NOT NULL REFERENCES henvalt.recovery_interventions(id) ON DELETE RESTRICT,
  retry_command_id uuid NOT NULL,
  generation_number integer NOT NULL CHECK (generation_number > 1),
  delivery_request_id uuid NOT NULL UNIQUE REFERENCES henvalt.delivery_requests(id) ON DELETE RESTRICT,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  PRIMARY KEY (tenant_id, intervention_id, retry_command_id),
  UNIQUE (tenant_id, intervention_id, generation_number)
);

CREATE TABLE IF NOT EXISTS henvalt.delivery_generation_incidents (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id uuid NOT NULL,
  intervention_id uuid NOT NULL REFERENCES henvalt.recovery_interventions(id) ON DELETE RESTRICT,
  delivery_request_id uuid NOT NULL REFERENCES henvalt.delivery_requests(id) ON DELETE RESTRICT,
  provider_event_id uuid REFERENCES henvalt.provider_events(id) ON DELETE RESTRICT,
  incident_type text NOT NULL CHECK (incident_type IN (
    'LATE_PROVIDER_ACCEPTANCE',
    'PROVIDER_IDENTITY_CONFLICT',
    'GENERATION_EGRESS_CONTRADICTION'
  )),
  details jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp()
);

ALTER TABLE henvalt.delivery_retry_commands ENABLE ROW LEVEL SECURITY;
ALTER TABLE henvalt.delivery_generation_incidents ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON henvalt.delivery_retry_commands FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON henvalt.delivery_generation_incidents FROM PUBLIC, anon, authenticated, service_role;

COMMENT ON COLUMN henvalt.delivery_requests.generation_number IS
  'Immutable ordinal within tenant/intervention delivery lifecycle; existing requests backfill to generation 1.';
COMMENT ON COLUMN henvalt.delivery_requests.provider_egress_started_at IS
  'One-way durable marker committed immediately before provider HTTP egress; non-null means retry is forbidden.';
COMMENT ON COLUMN henvalt.recovery_interventions.delivery_frozen_at IS
  'One-way freeze set by contradictory/late provider evidence; blocks every newer generation.';
COMMENT ON TABLE henvalt.delivery_retry_commands IS
  'Idempotency ledger for generation creation commands; service-role only.';
COMMENT ON TABLE henvalt.delivery_generation_incidents IS
  'Append-only evidence of contradictory provider outcomes across delivery generations.';


CREATE OR REPLACE FUNCTION henvalt.enforce_delivery_generation_monotonicity()
RETURNS trigger
LANGUAGE plpgsql
SET search_path TO pg_catalog, henvalt, pg_temp
AS $function$
BEGIN
  IF TG_TABLE_NAME = 'delivery_requests' THEN
    IF NEW.generation_number IS DISTINCT FROM OLD.generation_number THEN
      RAISE EXCEPTION 'DELIVERY_GENERATION_NUMBER_IS_IMMUTABLE'
        USING ERRCODE = '55000';
    END IF;
    IF OLD.provider_egress_started_at IS NOT NULL
       AND NEW.provider_egress_started_at IS DISTINCT FROM OLD.provider_egress_started_at THEN
      RAISE EXCEPTION 'DELIVERY_PROVIDER_EGRESS_MARKER_IS_IMMUTABLE'
        USING ERRCODE = '55000';
    END IF;
  ELSIF TG_TABLE_NAME = 'recovery_interventions' THEN
    IF OLD.delivery_frozen_at IS NOT NULL
       AND (NEW.delivery_frozen_at IS DISTINCT FROM OLD.delivery_frozen_at
         OR NEW.delivery_freeze_reason IS DISTINCT FROM OLD.delivery_freeze_reason) THEN
      RAISE EXCEPTION 'DELIVERY_INTERVENTION_FREEZE_IS_IMMUTABLE'
        USING ERRCODE = '55000';
    END IF;
  END IF;
  RETURN NEW;
END;
$function$;

REVOKE ALL ON FUNCTION henvalt.enforce_delivery_generation_monotonicity()
  FROM PUBLIC, anon, authenticated, service_role;

DROP TRIGGER IF EXISTS delivery_requests_generation_monotonicity
  ON henvalt.delivery_requests;
CREATE TRIGGER delivery_requests_generation_monotonicity
BEFORE UPDATE ON henvalt.delivery_requests
FOR EACH ROW EXECUTE FUNCTION henvalt.enforce_delivery_generation_monotonicity();

DROP TRIGGER IF EXISTS recovery_interventions_delivery_freeze_monotonicity
  ON henvalt.recovery_interventions;
CREATE TRIGGER recovery_interventions_delivery_freeze_monotonicity
BEFORE UPDATE ON henvalt.recovery_interventions
FOR EACH ROW EXECUTE FUNCTION henvalt.enforce_delivery_generation_monotonicity();

CREATE OR REPLACE FUNCTION henvalt.reject_delivery_generation_ledger_mutation()
RETURNS trigger
LANGUAGE plpgsql
SET search_path TO pg_catalog, henvalt, pg_temp
AS $function$
BEGIN
  RAISE EXCEPTION 'DELIVERY_GENERATION_LEDGER_IS_APPEND_ONLY'
    USING ERRCODE = '55000';
END;
$function$;

REVOKE ALL ON FUNCTION henvalt.reject_delivery_generation_ledger_mutation()
  FROM PUBLIC, anon, authenticated, service_role;

DROP TRIGGER IF EXISTS delivery_retry_commands_append_only
  ON henvalt.delivery_retry_commands;
CREATE TRIGGER delivery_retry_commands_append_only
BEFORE UPDATE OR DELETE ON henvalt.delivery_retry_commands
FOR EACH ROW EXECUTE FUNCTION henvalt.reject_delivery_generation_ledger_mutation();

DROP TRIGGER IF EXISTS delivery_generation_incidents_append_only
  ON henvalt.delivery_generation_incidents;
CREATE TRIGGER delivery_generation_incidents_append_only
BEFORE UPDATE OR DELETE ON henvalt.delivery_generation_incidents
FOR EACH ROW EXECUTE FUNCTION henvalt.reject_delivery_generation_ledger_mutation();

CREATE OR REPLACE FUNCTION henvalt.create_delivery_retry_generation(
  p_tenant_id uuid,
  p_intervention_id uuid,
  p_retry_command_id uuid
) RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO pg_catalog, henvalt, pg_temp
AS $function$
DECLARE
  v_intervention henvalt.recovery_interventions%ROWTYPE;
  v_previous henvalt.delivery_requests%ROWTYPE;
  v_attempt henvalt.delivery_attempts%ROWTYPE;
  v_reservation henvalt.email_usage_reservations%ROWTYPE;
  v_existing uuid;
  v_generation integer;
  v_new_request uuid;
  v_release_proof boolean;
BEGIN
  IF auth.role() IS DISTINCT FROM 'service_role' THEN
    RAISE EXCEPTION 'SERVICE_ROLE_REQUIRED' USING ERRCODE = '42501';
  END IF;
  IF p_tenant_id IS NULL OR p_intervention_id IS NULL OR p_retry_command_id IS NULL THEN
    RAISE EXCEPTION 'RETRY_COMMAND_IDENTITY_REQUIRED' USING ERRCODE = '22023';
  END IF;

  -- Canonical lifecycle lock order starts with the parent intervention.
  SELECT * INTO v_intervention
    FROM henvalt.recovery_interventions
   WHERE id=p_intervention_id AND tenant_id=p_tenant_id
   FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'INTERVENTION_NOT_FOUND'; END IF;

  -- Idempotency is checked only after the parent lock, serializing all commands
  -- for this intervention while keeping same-command retries deterministic.
  SELECT delivery_request_id INTO v_existing
    FROM henvalt.delivery_retry_commands
   WHERE tenant_id=p_tenant_id
     AND intervention_id=p_intervention_id
     AND retry_command_id=p_retry_command_id;
  IF FOUND THEN RETURN v_existing; END IF;

  IF v_intervention.delivery_frozen_at IS NOT NULL THEN
    RAISE EXCEPTION 'INTERVENTION_DELIVERY_FROZEN';
  END IF;
  IF v_intervention.status <> 'FAILED' THEN
    RAISE EXCEPTION 'INTERVENTION_NOT_RETRYABLE';
  END IF;

  SELECT * INTO v_previous
    FROM henvalt.delivery_requests
   WHERE tenant_id=p_tenant_id AND intervention_id=p_intervention_id
   ORDER BY generation_number DESC
   LIMIT 1
   FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'DELIVERY_GENERATION_NOT_FOUND'; END IF;

  IF v_previous.status <> 'FAILED'
     OR v_previous.provider_egress_started_at IS NOT NULL THEN
    RAISE EXCEPTION 'PREVIOUS_GENERATION_NOT_PROVEN_PRE_PROVIDER';
  END IF;

  SELECT * INTO v_attempt
    FROM henvalt.delivery_attempts
   WHERE tenant_id=p_tenant_id AND delivery_request_id=v_previous.id
   ORDER BY attempt_number DESC
   LIMIT 1;
  IF NOT FOUND
     OR v_attempt.state::text NOT IN ('FAILED','REJECTED')
     OR v_attempt.provider_response->>'henvalt_delivery_stage' <> 'pre_provider' THEN
    RAISE EXCEPTION 'SERVER_PROVEN_PRE_PROVIDER_FAILURE_REQUIRED';
  END IF;

  SELECT * INTO v_reservation
    FROM henvalt.email_usage_reservations
   WHERE tenant_id=p_tenant_id AND delivery_request_id=v_previous.id
   FOR UPDATE;
  IF NOT FOUND OR v_reservation.status <> 'RELEASED'
     OR v_reservation.last_attempt_id IS DISTINCT FROM v_attempt.id THEN
    RAISE EXCEPTION 'PREVIOUS_QUOTA_RESERVATION_NOT_RELEASED_BY_LATEST_ATTEMPT';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM henvalt.email_usage_reservation_events e
     WHERE e.reservation_id=v_reservation.id
       AND e.delivery_request_id=v_previous.id
       AND e.tenant_id=p_tenant_id
       AND e.event_type='RELEASED'
       AND e.delivery_attempt_id=v_attempt.id
       AND e.new_status='RELEASED'
  ) THEN
    RAISE EXCEPTION 'APPEND_ONLY_RELEASE_EVIDENCE_MISSING';
  END IF;

  -- A RELEASED hold alone is insufficient. It must correspond to the
  -- server-authored pre-provider marker or a definitive rejection allowlist.
  v_release_proof :=
    v_attempt.provider_response->>'henvalt_delivery_stage' = 'pre_provider'
    OR v_attempt.provider_status_code IN (400,401,403,404,405,410,413,415,422);
  IF NOT v_release_proof THEN
    RAISE EXCEPTION 'QUOTA_RELEASE_NOT_SUPPORTED_BY_TRUSTED_EVIDENCE';
  END IF;

  IF EXISTS (
    SELECT 1 FROM henvalt.provider_events
     WHERE delivery_request_id=v_previous.id
  ) THEN
    RAISE EXCEPTION 'PROVIDER_EVIDENCE_ALREADY_EXISTS';
  END IF;

  v_generation := v_previous.generation_number + 1;

  INSERT INTO henvalt.delivery_requests (
    tenant_id, intervention_id, recovery_id, opportunity_id, channel,
    delivery_mode, recipient_reference, message_reference, template_reference,
    tracking_token, scheduled_at, status, provider, provider_message_id,
    idempotency_key, correlation_id, generation_number
  ) VALUES (
    v_previous.tenant_id, v_previous.intervention_id, v_previous.recovery_id,
    v_previous.opportunity_id, v_previous.channel, v_previous.delivery_mode,
    v_previous.recipient_reference, v_previous.message_reference,
    v_previous.template_reference, v_previous.tracking_token,
    v_previous.scheduled_at, 'PENDING', v_previous.provider, NULL,
    'deliver:' || p_intervention_id::text || ':g' || v_generation::text,
    v_previous.correlation_id, v_generation
  ) RETURNING id INTO v_new_request;

  INSERT INTO henvalt.delivery_retry_commands (
    tenant_id, intervention_id, retry_command_id, generation_number, delivery_request_id
  ) VALUES (
    p_tenant_id, p_intervention_id, p_retry_command_id, v_generation, v_new_request
  );

  -- Do not create a quota reservation here. The existing entitlement trigger
  -- creates it atomically at PENDING -> UNKNOWN, after the current-generation
  -- claim succeeds. This avoids diverging from the production billing lifecycle.
  UPDATE henvalt.recovery_interventions
     SET status='SENDING', updated_at=clock_timestamp()
   WHERE id=p_intervention_id AND tenant_id=p_tenant_id AND status='FAILED';
  IF NOT FOUND THEN RAISE EXCEPTION 'INTERVENTION_RETRY_STATE_CHANGED'; END IF;

  RETURN v_new_request;
END;
$function$;

REVOKE ALL ON FUNCTION henvalt.create_delivery_retry_generation(uuid,uuid,uuid)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION henvalt.create_delivery_retry_generation(uuid,uuid,uuid)
  TO service_role;

COMMIT;

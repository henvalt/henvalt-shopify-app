-- Queue-backed immutable delivery retry generations.
-- Depends on 202611230002_delivery_generation_schema_and_retry_rpc.sql and
-- the existing background_jobs worker table. Candidate only; do not deploy
-- until the coordinated recovery/delivery graph and isolated staging pass.

BEGIN;

-- Keep the retry command ledger append-only. The separate mapping is
-- also append-only, so a command can be linked to one queued job without
-- mutating the immutable generation command record.
CREATE TABLE IF NOT EXISTS henvalt.delivery_retry_jobs (
  tenant_id uuid NOT NULL,
  intervention_id uuid NOT NULL,
  retry_command_id uuid NOT NULL,
  delivery_request_id uuid NOT NULL UNIQUE
    REFERENCES henvalt.delivery_requests(id) ON DELETE RESTRICT,
  job_id uuid NOT NULL UNIQUE
    REFERENCES henvalt.background_jobs(id) ON DELETE RESTRICT,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  PRIMARY KEY (tenant_id,intervention_id,retry_command_id),
  FOREIGN KEY (tenant_id,intervention_id,retry_command_id)
    REFERENCES henvalt.delivery_retry_commands(tenant_id,intervention_id,retry_command_id)
    ON DELETE RESTRICT
);

ALTER TABLE henvalt.delivery_retry_jobs ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON henvalt.delivery_retry_jobs FROM PUBLIC,anon,authenticated,service_role;
DROP TRIGGER IF EXISTS delivery_retry_jobs_append_only ON henvalt.delivery_retry_jobs;
CREATE TRIGGER delivery_retry_jobs_append_only
  BEFORE UPDATE OR DELETE ON henvalt.delivery_retry_jobs
  FOR EACH ROW EXECUTE FUNCTION henvalt.reject_delivery_generation_ledger_mutation();

CREATE OR REPLACE FUNCTION henvalt.enqueue_delivery_retry_generation_job(
  p_tenant_id uuid,
  p_intervention_id uuid,
  p_source_job_id uuid,
  p_worker_id text
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO pg_catalog, henvalt, auth, pg_temp
AS $function$
DECLARE
  v_intervention henvalt.recovery_interventions%ROWTYPE;
  v_source_job henvalt.background_jobs%ROWTYPE;
  v_previous henvalt.delivery_requests%ROWTYPE;
  v_attempt henvalt.delivery_attempts%ROWTYPE;
  v_reservation henvalt.email_usage_reservations%ROWTYPE;
  v_new_request uuid;
  v_retry_job_id uuid;
  v_retry_command_id uuid;
  v_generation integer;
  v_rows integer;
BEGIN
  IF auth.role() IS DISTINCT FROM 'service_role' THEN
    RAISE EXCEPTION 'SERVICE_ROLE_REQUIRED' USING ERRCODE='42501';
  END IF;
  IF p_tenant_id IS NULL OR p_intervention_id IS NULL
     OR p_source_job_id IS NULL OR NULLIF(btrim(p_worker_id),'') IS NULL THEN
    RAISE EXCEPTION 'DELIVERY_RETRY_JOB_IDENTITY_REQUIRED' USING ERRCODE='22023';
  END IF;

  -- Canonical lifecycle lock order: intervention -> request -> reservation.
  SELECT ri.* INTO v_intervention
    FROM henvalt.recovery_interventions ri
   WHERE ri.id=p_intervention_id AND ri.tenant_id=p_tenant_id
   FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'INTERVENTION_NOT_FOUND'; END IF;

  -- Read the claimed job without taking a child-first lock. The final UPDATE
  -- below is the compare-and-set that proves this worker still owns the job.
  SELECT * INTO v_source_job
    FROM henvalt.background_jobs
   WHERE id=p_source_job_id;
  IF NOT FOUND
     OR v_source_job.status <> 'CLAIMED'
     OR v_source_job.locked_by IS DISTINCT FROM p_worker_id
     OR v_source_job.job_type NOT IN ('execute_intervention','execute_delivery_retry_generation')
     OR v_source_job.payload->>'intervention_id' IS DISTINCT FROM p_intervention_id::text
     OR (v_source_job.tenant_id IS NOT NULL AND v_source_job.tenant_id <> p_tenant_id) THEN
    RAISE EXCEPTION 'DELIVERY_RETRY_SOURCE_JOB_CLAIM_INVALID' USING ERRCODE='55000';
  END IF;

  IF v_intervention.delivery_frozen_at IS NOT NULL THEN
    UPDATE henvalt.background_jobs
       SET status='SUCCEEDED',completed_at=clock_timestamp(),
           locked_at=NULL,locked_by=NULL,updated_at=clock_timestamp()
     WHERE id=p_source_job_id AND status='CLAIMED' AND locked_by=p_worker_id;
    GET DIAGNOSTICS v_rows=ROW_COUNT;
    IF v_rows<>1 THEN RAISE EXCEPTION 'DELIVERY_RETRY_SOURCE_JOB_CLAIM_LOST'; END IF;
    RETURN jsonb_build_object('action','BLOCKED','reason','INTERVENTION_DELIVERY_FROZEN');
  END IF;

  SELECT * INTO v_previous
    FROM henvalt.delivery_requests
   WHERE tenant_id=p_tenant_id AND intervention_id=p_intervention_id
   ORDER BY generation_number DESC
   LIMIT 1;
  IF NOT FOUND OR v_previous.status <> 'FAILED'
     OR v_previous.provider_egress_started_at IS NOT NULL THEN
    RETURN jsonb_build_object('action','CONTINUE_NORMAL');
  END IF;

  IF v_source_job.job_type='execute_delivery_retry_generation'
     AND (v_source_job.payload->>'delivery_request_id' IS DISTINCT FROM v_previous.id::text
       OR (v_source_job.payload->>'generation_number')::integer IS DISTINCT FROM v_previous.generation_number) THEN
    RAISE EXCEPTION 'DELIVERY_RETRY_JOB_GENERATION_STALE' USING ERRCODE='55000';
  END IF;

  SELECT * INTO v_attempt
    FROM henvalt.delivery_attempts
   WHERE tenant_id=p_tenant_id AND delivery_request_id=v_previous.id
   ORDER BY attempt_number DESC
   LIMIT 1;
  IF NOT FOUND
     OR v_attempt.state::text NOT IN ('FAILED','REJECTED')
     OR v_attempt.provider_response->>'henvalt_delivery_stage' IS DISTINCT FROM 'pre_provider' THEN
    RETURN jsonb_build_object('action','CONTINUE_NORMAL');
  END IF;

  -- Snapshot-only precheck. The underlying generation RPC re-locks the
  -- request before it locks and validates this reservation, preserving
  -- intervention -> request -> reservation ordering.
  SELECT * INTO v_reservation
    FROM henvalt.email_usage_reservations
   WHERE tenant_id=p_tenant_id AND delivery_request_id=v_previous.id;
  IF NOT FOUND OR v_reservation.status <> 'RELEASED'
     OR v_reservation.last_attempt_id IS DISTINCT FROM v_attempt.id THEN
    RETURN jsonb_build_object('action','CONTINUE_NORMAL');
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM henvalt.email_usage_reservation_events e
     WHERE e.reservation_id=v_reservation.id
       AND e.delivery_request_id=v_previous.id
       AND e.tenant_id=p_tenant_id
       AND e.event_type='RELEASED'
       AND e.delivery_attempt_id=v_attempt.id
       AND e.new_status='RELEASED'
       AND e.reason=v_reservation.status_reason
  ) THEN
    RETURN jsonb_build_object('action','CONTINUE_NORMAL');
  END IF;
  IF EXISTS (
    SELECT 1 FROM henvalt.provider_events
     WHERE delivery_request_id=v_previous.id
  ) THEN
    RETURN jsonb_build_object('action','CONTINUE_NORMAL');
  END IF;

  -- Recover a worker crash between recording the provider result and resolving
  -- the intervention. This transition is allowed only after the exact server
  -- pre-provider marker and released reservation have been proven above.
  IF v_intervention.status='SENDING' THEN
    PERFORM henvalt.resolve_intervention_send_failure(
      p_intervention_id,'FAILED'::henvalt.intervention_status,
      'PRE_PROVIDER_FAILURE_RETRY_RECOVERY'
    );
    SELECT * INTO v_intervention
      FROM henvalt.recovery_interventions
     WHERE id=p_intervention_id AND tenant_id=p_tenant_id
     FOR UPDATE;
  END IF;
  IF v_intervention.status <> 'FAILED' THEN
    RETURN jsonb_build_object('action','CONTINUE_NORMAL');
  END IF;

  -- Two retries maximum: generations 1, 2 and 3. This prevents a permanent
  -- configuration fault from creating an unbounded queue of no-egress jobs.
  IF v_previous.generation_number >= 3 THEN
    UPDATE henvalt.background_jobs
       SET status='DEAD_LETTER',
           next_run_at=NULL,
           last_error='DELIVERY_GENERATION_RETRY_LIMIT_REACHED',
           locked_at=NULL,locked_by=NULL,updated_at=clock_timestamp()
     WHERE id=p_source_job_id AND status='CLAIMED' AND locked_by=p_worker_id;
    GET DIAGNOSTICS v_rows=ROW_COUNT;
    IF v_rows<>1 THEN RAISE EXCEPTION 'DELIVERY_RETRY_SOURCE_JOB_CLAIM_LOST'; END IF;
    RETURN jsonb_build_object('action','DEAD_LETTER','reason','DELIVERY_GENERATION_RETRY_LIMIT_REACHED');
  END IF;

  v_retry_command_id := v_attempt.id;
  v_new_request := henvalt.create_delivery_retry_generation(
    p_tenant_id,p_intervention_id,v_retry_command_id
  );

  SELECT generation_number INTO v_generation
    FROM henvalt.delivery_requests
   WHERE id=v_new_request AND tenant_id=p_tenant_id
     AND intervention_id=p_intervention_id;
  IF v_generation IS NULL OR v_generation <> v_previous.generation_number+1 THEN
    RAISE EXCEPTION 'DELIVERY_RETRY_GENERATION_RESULT_INVALID';
  END IF;

  SELECT job_id INTO v_retry_job_id
    FROM henvalt.delivery_retry_jobs
   WHERE tenant_id=p_tenant_id
     AND intervention_id=p_intervention_id
     AND retry_command_id=v_retry_command_id
   FOR UPDATE;

  IF v_retry_job_id IS NULL THEN
    INSERT INTO henvalt.background_jobs (
      tenant_id,job_type,payload,status,priority,attempts,max_attempts,
      run_at,correlation_id,idempotency_key
    ) VALUES (
      p_tenant_id,
      'execute_delivery_retry_generation',
      jsonb_build_object(
        'tenant_id',p_tenant_id,
        'intervention_id',p_intervention_id,
        'delivery_request_id',v_new_request,
        'generation_number',v_generation,
        'source_retry_command_id',v_retry_command_id
      ),
      'QUEUED'::henvalt.job_status,
      25,0,3,clock_timestamp(),v_previous.correlation_id,
      'delivery-retry:'||v_retry_command_id::text
    ) RETURNING id INTO v_retry_job_id;

    INSERT INTO henvalt.delivery_retry_jobs(
      tenant_id,intervention_id,retry_command_id,delivery_request_id,job_id
    ) VALUES (
      p_tenant_id,p_intervention_id,v_retry_command_id,v_new_request,v_retry_job_id
    );
  END IF;

  UPDATE henvalt.background_jobs
     SET status='SUCCEEDED',completed_at=clock_timestamp(),
         locked_at=NULL,locked_by=NULL,updated_at=clock_timestamp()
   WHERE id=p_source_job_id AND status='CLAIMED' AND locked_by=p_worker_id;
  GET DIAGNOSTICS v_rows=ROW_COUNT;
  IF v_rows<>1 THEN RAISE EXCEPTION 'DELIVERY_RETRY_SOURCE_JOB_CLAIM_LOST'; END IF;

  RETURN jsonb_build_object(
    'action','RETRY_QUEUED',
    'delivery_request_id',v_new_request,
    'retry_job_id',v_retry_job_id,
    'generation_number',v_generation,
    'retry_command_id',v_retry_command_id
  );
END;
$function$;

CREATE OR REPLACE FUNCTION henvalt.enqueue_delivery_retry_generation_job(
  p_intervention_id uuid,
  p_source_job_id uuid,
  p_worker_id text
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO pg_catalog, henvalt, auth, pg_temp
AS $function$
DECLARE
  v_tenant_id uuid;
BEGIN
  IF auth.role() IS DISTINCT FROM 'service_role' THEN
    RAISE EXCEPTION 'SERVICE_ROLE_REQUIRED' USING ERRCODE='42501';
  END IF;
  SELECT tenant_id INTO v_tenant_id
    FROM henvalt.recovery_interventions
   WHERE id=p_intervention_id;
  IF v_tenant_id IS NULL THEN RAISE EXCEPTION 'INTERVENTION_NOT_FOUND'; END IF;
  RETURN henvalt.enqueue_delivery_retry_generation_job(
    v_tenant_id,p_intervention_id,p_source_job_id,p_worker_id
  );
END;
$function$;

CREATE OR REPLACE FUNCTION henvalt.enqueue_delivery_retry_generation_job(
  p_intervention_id uuid,
  p_source_job_id uuid,
  p_worker_id text,
  p_expected_delivery_request_id uuid,
  p_expected_delivery_attempt_id uuid
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO pg_catalog, henvalt, auth, pg_temp
AS $function$
DECLARE
  v_intervention henvalt.recovery_interventions%ROWTYPE;
  v_request henvalt.delivery_requests%ROWTYPE;
  v_attempt henvalt.delivery_attempts%ROWTYPE;
BEGIN
  IF auth.role() IS DISTINCT FROM 'service_role' THEN
    RAISE EXCEPTION 'SERVICE_ROLE_REQUIRED' USING ERRCODE='42501';
  END IF;
  SELECT * INTO v_intervention
    FROM henvalt.recovery_interventions
   WHERE id=p_intervention_id
   FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'INTERVENTION_NOT_FOUND'; END IF;

  SELECT * INTO v_request
    FROM henvalt.delivery_requests
   WHERE tenant_id=v_intervention.tenant_id
     AND intervention_id=p_intervention_id
   ORDER BY generation_number DESC
   LIMIT 1
   FOR UPDATE;
  IF NOT FOUND OR v_request.id IS DISTINCT FROM p_expected_delivery_request_id THEN
    RAISE EXCEPTION 'DELIVERY_RETRY_EXPECTED_REQUEST_STALE' USING ERRCODE='55000';
  END IF;

  SELECT * INTO v_attempt
    FROM henvalt.delivery_attempts
   WHERE tenant_id=v_intervention.tenant_id
     AND delivery_request_id=v_request.id
   ORDER BY attempt_number DESC
   LIMIT 1;
  IF NOT FOUND OR v_attempt.id IS DISTINCT FROM p_expected_delivery_attempt_id THEN
    RAISE EXCEPTION 'DELIVERY_RETRY_EXPECTED_ATTEMPT_STALE' USING ERRCODE='55000';
  END IF;

  RETURN henvalt.enqueue_delivery_retry_generation_job(
    v_intervention.tenant_id,p_intervention_id,p_source_job_id,p_worker_id
  );
END;
$function$;

CREATE OR REPLACE FUNCTION henvalt.load_delivery_retry_envelope(
  p_job_id uuid,
  p_worker_id text,
  p_tenant_id uuid,
  p_intervention_id uuid,
  p_delivery_request_id uuid,
  p_generation_number integer
) RETURNS TABLE (
  delivery_request_id uuid,
  tenant_id uuid,
  intervention_id uuid,
  recovery_id uuid,
  opportunity_id uuid,
  message_id uuid,
  channel text,
  delivery_mode text,
  recipient text,
  subject text,
  html_body text,
  text_body text,
  tracking_token text,
  idempotency_key text,
  correlation_id uuid
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO pg_catalog, henvalt, auth, pg_temp
AS $function$
DECLARE
  v_intervention henvalt.recovery_interventions%ROWTYPE;
  v_request henvalt.delivery_requests%ROWTYPE;
  v_job henvalt.background_jobs%ROWTYPE;
BEGIN
  IF auth.role() IS DISTINCT FROM 'service_role' THEN
    RAISE EXCEPTION 'SERVICE_ROLE_REQUIRED' USING ERRCODE='42501';
  END IF;

  SELECT * INTO v_job
    FROM henvalt.background_jobs
   WHERE id=p_job_id;
  IF NOT FOUND
     OR v_job.job_type <> 'execute_delivery_retry_generation'
     OR v_job.status <> 'CLAIMED'
     OR v_job.locked_by IS DISTINCT FROM p_worker_id
     OR v_job.locked_at IS NULL
     OR v_job.locked_at < clock_timestamp() - interval '900 seconds'
     OR v_job.tenant_id IS DISTINCT FROM p_tenant_id
     OR v_job.payload->>'tenant_id' IS DISTINCT FROM p_tenant_id::text
     OR v_job.payload->>'intervention_id' IS DISTINCT FROM p_intervention_id::text
     OR v_job.payload->>'delivery_request_id' IS DISTINCT FROM p_delivery_request_id::text
     OR (v_job.payload->>'generation_number')::integer IS DISTINCT FROM p_generation_number THEN
    RAISE EXCEPTION 'DELIVERY_RETRY_JOB_CLAIM_INVALID' USING ERRCODE='55000';
  END IF;

  -- Parent-first lock order is shared with authorization, result, webhook and
  -- generation creation. The provider egress RPC rechecks this state again.
  SELECT ri.* INTO v_intervention
    FROM henvalt.recovery_interventions ri
   WHERE ri.id=p_intervention_id AND ri.tenant_id=p_tenant_id
   FOR UPDATE;
  IF NOT FOUND OR v_intervention.delivery_frozen_at IS NOT NULL
     OR v_intervention.status <> 'SENDING' THEN
    RETURN;
  END IF;

  SELECT dr.* INTO v_request
    FROM henvalt.delivery_requests dr
   WHERE dr.id=p_delivery_request_id
     AND dr.tenant_id=p_tenant_id
     AND dr.intervention_id=p_intervention_id
     AND dr.generation_number=p_generation_number
   FOR UPDATE;

  -- Reclaim a retry request that was claimed by a worker which crashed before
  -- the one-way provider-egress marker. No provider HTTP call can precede that
  -- marker. Require the same live job lease, a RESERVED quota hold, and zero
  -- attempt/provider-event evidence before returning it to PENDING.
  IF FOUND
     AND v_request.status='UNKNOWN'
     AND v_request.provider_egress_started_at IS NULL
     AND NOT EXISTS (
       SELECT 1 FROM henvalt.delivery_attempts da
        WHERE da.tenant_id=p_tenant_id
          AND da.delivery_request_id=p_delivery_request_id
     )
     AND NOT EXISTS (
       SELECT 1 FROM henvalt.provider_events pe
        WHERE pe.tenant_id=p_tenant_id
          AND pe.delivery_request_id=p_delivery_request_id
     )
     AND EXISTS (
       SELECT 1 FROM henvalt.email_usage_reservations eur
        WHERE eur.tenant_id=p_tenant_id
          AND eur.delivery_request_id=p_delivery_request_id
          AND eur.status='RESERVED'
     ) THEN
    SELECT * INTO v_job
      FROM henvalt.background_jobs
     WHERE id=p_job_id
     FOR UPDATE;
    IF NOT FOUND
       OR v_job.job_type <> 'execute_delivery_retry_generation'
       OR v_job.status <> 'CLAIMED'
       OR v_job.locked_by IS DISTINCT FROM p_worker_id
       OR v_job.locked_at IS NULL
       OR v_job.locked_at < clock_timestamp()-interval '900 seconds'
       OR v_job.tenant_id IS DISTINCT FROM p_tenant_id
       OR v_job.payload->>'tenant_id' IS DISTINCT FROM p_tenant_id::text
       OR v_job.payload->>'intervention_id' IS DISTINCT FROM p_intervention_id::text
       OR v_job.payload->>'delivery_request_id' IS DISTINCT FROM p_delivery_request_id::text
       OR (v_job.payload->>'generation_number')::integer IS DISTINCT FROM p_generation_number THEN
      RAISE EXCEPTION 'DELIVERY_RETRY_JOB_CLAIM_INVALID' USING ERRCODE='55000';
    END IF;

    UPDATE henvalt.delivery_requests
       SET status='PENDING',
           provider_claimed_at=NULL,
           updated_at=clock_timestamp()
     WHERE id=p_delivery_request_id
       AND tenant_id=p_tenant_id
       AND status='UNKNOWN'
       AND provider_egress_started_at IS NULL;
    IF NOT FOUND THEN RAISE EXCEPTION 'DELIVERY_RETRY_RECOVERY_COMPARE_AND_SET_LOST'; END IF;

    SELECT dr.* INTO v_request
      FROM henvalt.delivery_requests dr
     WHERE dr.id=p_delivery_request_id
       AND dr.tenant_id=p_tenant_id
       AND dr.intervention_id=p_intervention_id
       AND dr.generation_number=p_generation_number
     FOR UPDATE;
  END IF;

  IF NOT FOUND OR v_request.status <> 'PENDING'
     OR v_request.channel <> 'EMAIL'
     OR lower(COALESCE(v_request.provider,'')) <> 'mailersend'
     OR v_request.tracking_token IS NULL
     OR v_request.provider_claimed_at IS NOT NULL
     OR v_request.provider_egress_started_at IS NOT NULL
     -- A persisted attempt or provider event is contradictory evidence for a
     -- never-attempted retry request. Do not load an envelope while webhook
     -- settlement or an unmarked send outcome may still be in flight.
     OR EXISTS (
       SELECT 1 FROM henvalt.delivery_attempts da
        WHERE da.tenant_id=p_tenant_id
          AND da.delivery_request_id=p_delivery_request_id
     )
     OR EXISTS (
       SELECT 1 FROM henvalt.provider_events pe
        WHERE pe.tenant_id=p_tenant_id
          AND pe.delivery_request_id=p_delivery_request_id
     )
     OR EXISTS (
       SELECT 1 FROM henvalt.delivery_requests newer
        WHERE newer.tenant_id=p_tenant_id
          AND newer.intervention_id=p_intervention_id
          AND newer.generation_number>p_generation_number
     ) THEN
    RETURN;
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM henvalt.delivery_retry_jobs rj
     WHERE rj.tenant_id=p_tenant_id
       AND rj.intervention_id=p_intervention_id
       AND rj.delivery_request_id=p_delivery_request_id
       AND rj.job_id=p_job_id
  ) THEN
    RETURN;
  END IF;

  RETURN QUERY
  SELECT
    v_request.id,
    v_request.tenant_id,
    v_request.intervention_id,
    v_request.recovery_id,
    v_request.opportunity_id,
    m.id,
    v_request.channel::text,
    v_request.delivery_mode::text,
    v_request.recipient_reference,
    m.subject,
    henvalt.render_sender_identity_footer(p_tenant_id,m.body),
    henvalt.render_email_plain_text(
      henvalt.render_sender_identity_footer(p_tenant_id,m.body)
    ),
    v_request.tracking_token,
    v_request.idempotency_key,
    v_request.correlation_id
  FROM henvalt.messages m
  WHERE m.id=v_request.message_reference
    AND m.tenant_id=p_tenant_id
    AND m.intervention_id=p_intervention_id
    AND m.channel=v_request.channel
    AND m.recipient=v_request.recipient_reference
    AND m.subject IS NOT NULL
    AND NULLIF(btrim(m.body),'') IS NOT NULL;

  IF NOT FOUND THEN
    RETURN;
  END IF;
END;
$function$;


-- Final provider-egress ownership check for a queued retry generation.
-- The loader check is not sufficient on its own: a worker can lose its
-- 15-minute background-job lease after loading the immutable envelope.
-- Lock order remains intervention -> delivery request -> background job.

-- Renew a retry job lease only while the exact worker still owns the current
-- generation. Called before token release and again atomically at final egress.
-- Canonical lock order: intervention -> request -> background job.
CREATE OR REPLACE FUNCTION henvalt.renew_delivery_retry_job_lease(
  p_tenant_id uuid,
  p_delivery_request_id uuid,
  p_retry_job_id uuid,
  p_retry_worker_id text,
  p_generation_number integer
) RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO pg_catalog, henvalt, auth, pg_temp
AS $function$
DECLARE
  v_intervention_id uuid;
  v_intervention henvalt.recovery_interventions%ROWTYPE;
  v_request henvalt.delivery_requests%ROWTYPE;
  v_job henvalt.background_jobs%ROWTYPE;
BEGIN
  IF auth.role() IS DISTINCT FROM 'service_role' THEN
    RAISE EXCEPTION 'SERVICE_ROLE_REQUIRED' USING ERRCODE='42501';
  END IF;
  IF p_tenant_id IS NULL OR p_delivery_request_id IS NULL
     OR p_retry_job_id IS NULL OR NULLIF(btrim(p_retry_worker_id),'') IS NULL
     OR p_generation_number NOT IN (2,3) THEN
    RAISE EXCEPTION 'DELIVERY_RETRY_EGRESS_IDENTITY_REQUIRED' USING ERRCODE='22023';
  END IF;

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

  SELECT * INTO v_job
    FROM henvalt.background_jobs j
   WHERE j.id=p_retry_job_id
   FOR UPDATE;
  IF NOT FOUND
     OR v_job.job_type <> 'execute_delivery_retry_generation'
     OR v_job.status <> 'CLAIMED'
     OR v_job.locked_by IS DISTINCT FROM p_retry_worker_id
     OR v_job.locked_at IS NULL
     OR v_job.locked_at < clock_timestamp() - interval '900 seconds'
     OR v_job.tenant_id IS DISTINCT FROM p_tenant_id
     OR v_job.payload->>'tenant_id' IS DISTINCT FROM p_tenant_id::text
     OR v_job.payload->>'intervention_id' IS DISTINCT FROM v_intervention_id::text
     OR v_job.payload->>'delivery_request_id' IS DISTINCT FROM p_delivery_request_id::text
     OR (v_job.payload->>'generation_number')::integer IS DISTINCT FROM p_generation_number
     OR NOT EXISTS (
       SELECT 1 FROM henvalt.delivery_retry_jobs rj
        WHERE rj.tenant_id=p_tenant_id
          AND rj.intervention_id=v_intervention_id
          AND rj.delivery_request_id=p_delivery_request_id
          AND rj.job_id=p_retry_job_id
     ) THEN
    RAISE EXCEPTION 'DELIVERY_RETRY_JOB_CLAIM_INVALID' USING ERRCODE='55000';
  END IF;

  IF v_intervention.status <> 'SENDING'
     OR v_intervention.delivery_frozen_at IS NOT NULL
     OR v_request.generation_number IS DISTINCT FROM p_generation_number
     OR v_request.status NOT IN ('PENDING','UNKNOWN')
     OR v_request.channel <> 'EMAIL'
     OR lower(COALESCE(v_request.provider,'')) <> 'mailersend'
     OR v_request.provider_egress_started_at IS NOT NULL
     OR EXISTS (
       SELECT 1 FROM henvalt.delivery_requests newer
        WHERE newer.tenant_id=p_tenant_id
          AND newer.intervention_id=v_intervention_id
          AND newer.generation_number>p_generation_number
     ) THEN
    RAISE EXCEPTION 'DELIVERY_RETRY_GENERATION_NOT_SENDABLE' USING ERRCODE='55000';
  END IF;

  UPDATE henvalt.background_jobs
     SET locked_at=clock_timestamp(),updated_at=clock_timestamp()
   WHERE id=p_retry_job_id AND status='CLAIMED' AND locked_by=p_retry_worker_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'DELIVERY_RETRY_JOB_CLAIM_LOST' USING ERRCODE='55000'; END IF;
  RETURN true;
END;
$function$;


-- Authorization wrapper validates and renews retry ownership before the
-- canonical authorization RPC can transition the request from PENDING to
-- UNKNOWN. Normal deliveries pass NULL retry fields and retain old behavior.
CREATE OR REPLACE FUNCTION henvalt.authorize_delivery_request_with_retry_lease(
  p_tenant_id uuid,
  p_delivery_request_id uuid,
  p_intervention_id uuid,
  p_recovery_id uuid,
  p_opportunity_id uuid,
  p_recipient text,
  p_idempotency_key text,
  p_retry_job_id uuid,
  p_retry_worker_id text,
  p_generation_number integer
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO pg_catalog, henvalt, auth, pg_temp
AS $function$
BEGIN
  IF auth.role() IS DISTINCT FROM 'service_role' THEN
    RAISE EXCEPTION 'SERVICE_ROLE_REQUIRED' USING ERRCODE='42501';
  END IF;

  IF p_retry_job_id IS NULL AND p_retry_worker_id IS NULL AND p_generation_number IS NULL THEN
    RETURN henvalt.authorize_delivery_request(
      p_tenant_id,p_delivery_request_id,p_intervention_id,p_recovery_id,
      p_opportunity_id,p_recipient,p_idempotency_key
    );
  END IF;

  IF p_retry_job_id IS NULL OR NULLIF(btrim(p_retry_worker_id),'') IS NULL
     OR p_generation_number NOT IN (2,3) THEN
    RETURN jsonb_build_object(
      'can_send',false,
      'reason','RETRY_JOB_CLAIM_LOST',
      'retry_job_claim_lost',true
    );
  END IF;

  BEGIN
    PERFORM henvalt.renew_delivery_retry_job_lease(
      p_tenant_id,p_delivery_request_id,p_retry_job_id,
      p_retry_worker_id,p_generation_number
    );
  EXCEPTION
    WHEN SQLSTATE '55000' OR SQLSTATE '22023' OR SQLSTATE 'P0001' THEN
      RETURN jsonb_build_object(
        'can_send',false,
        'reason','RETRY_JOB_CLAIM_LOST',
        'retry_job_claim_lost',true
      );
  END;

  -- The lease helper holds intervention -> request -> job locks until this
  -- transaction completes. The canonical authorization RPC then claims the
  -- request under the same parent-first lifecycle order.
  RETURN henvalt.authorize_delivery_request(
    p_tenant_id,p_delivery_request_id,p_intervention_id,p_recovery_id,
    p_opportunity_id,p_recipient,p_idempotency_key
  );
END;
$function$;

REVOKE ALL ON FUNCTION henvalt.authorize_delivery_request_with_retry_lease(uuid,uuid,uuid,uuid,uuid,text,text,uuid,text,integer)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION henvalt.authorize_delivery_request_with_retry_lease(uuid,uuid,uuid,uuid,uuid,text,text,uuid,text,integer)
  TO service_role;

COMMENT ON FUNCTION henvalt.authorize_delivery_request_with_retry_lease(uuid,uuid,uuid,uuid,uuid,text,text,uuid,text,integer) IS
  'Delivery authorization wrapper. For retry generations it validates and renews the exact current retry worker lease before the canonical authorization RPC claims the delivery request; normal sends pass NULL retry identity.';

CREATE OR REPLACE FUNCTION henvalt.mark_mailersend_provider_egress_started(
  p_tenant_id uuid,
  p_delivery_request_id uuid,
  p_retry_job_id uuid,
  p_retry_worker_id text,
  p_generation_number integer
) RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO pg_catalog, henvalt, auth, pg_temp
AS $function$
BEGIN
  IF henvalt.renew_delivery_retry_job_lease(
    p_tenant_id,p_delivery_request_id,p_retry_job_id,p_retry_worker_id,p_generation_number
  ) IS NOT TRUE THEN
    RAISE EXCEPTION 'DELIVERY_RETRY_JOB_CLAIM_INVALID' USING ERRCODE='55000';
  END IF;
  -- The helper's parent/request/job locks remain held for this transaction.
  -- Reuse the canonical provider fence for the final send-state and global
  -- interlock checks, then commit the job heartbeat and egress marker together.
  RETURN henvalt.mark_mailersend_provider_egress_started(
    p_tenant_id,p_delivery_request_id
  );
END;
$function$;

REVOKE ALL ON FUNCTION henvalt.renew_delivery_retry_job_lease(uuid,uuid,uuid,text,integer)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION henvalt.renew_delivery_retry_job_lease(uuid,uuid,uuid,text,integer)
  TO service_role;

REVOKE ALL ON FUNCTION henvalt.mark_mailersend_provider_egress_started(uuid,uuid,uuid,text,integer)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION henvalt.mark_mailersend_provider_egress_started(uuid,uuid,uuid,text,integer)
  TO service_role;

COMMENT ON FUNCTION henvalt.mark_mailersend_provider_egress_started(uuid,uuid,uuid,text,integer) IS
  'Retry-only final egress fence. Revalidates exact tenant/request/job/worker/generation mapping and the 900-second job lease under intervention -> request -> job locks before delegating to the canonical provider egress fence.';

REVOKE ALL ON FUNCTION henvalt.enqueue_delivery_retry_generation_job(uuid,uuid,uuid,text)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION henvalt.enqueue_delivery_retry_generation_job(uuid,uuid,uuid,text)
  TO service_role;

REVOKE ALL ON FUNCTION henvalt.enqueue_delivery_retry_generation_job(uuid,uuid,text)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION henvalt.enqueue_delivery_retry_generation_job(uuid,uuid,text)
  TO service_role;

REVOKE ALL ON FUNCTION henvalt.enqueue_delivery_retry_generation_job(uuid,uuid,text,uuid,uuid)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION henvalt.enqueue_delivery_retry_generation_job(uuid,uuid,text,uuid,uuid)
  TO service_role;

REVOKE ALL ON FUNCTION henvalt.load_delivery_retry_envelope(uuid,text,uuid,uuid,uuid,integer)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION henvalt.load_delivery_retry_envelope(uuid,text,uuid,uuid,uuid,integer)
  TO service_role;

COMMENT ON FUNCTION henvalt.enqueue_delivery_retry_generation_job(uuid,uuid,uuid,text) IS
  'Atomically converts a proven pre-provider failure into an immutable next delivery generation and a dedicated recovery worker job; completes the source job in the same transaction.';
COMMENT ON FUNCTION henvalt.load_delivery_retry_envelope(uuid,text,uuid,uuid,uuid,integer) IS
  'Loads the immutable stored message envelope only for the currently claimed retry-generation job; parent-first lock order and egress checks are repeated before delivery authorization.';


-- An empty retry envelope is not always a corrupt message: the intervention may
-- have been frozen by late provider acceptance, or the job/request may have
-- become stale after the loader's initial checks. Revalidate under parent-first
-- locks before releasing quota or changing intervention state.
CREATE OR REPLACE FUNCTION henvalt.fail_delivery_retry_envelope_safely(
  p_tenant_id uuid,
  p_intervention_id uuid,
  p_delivery_request_id uuid,
  p_generation_number integer,
  p_retry_job_id uuid,
  p_retry_worker_id text
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO pg_catalog, henvalt, auth, pg_temp
AS $function$
DECLARE
  v_intervention henvalt.recovery_interventions%ROWTYPE;
  v_request henvalt.delivery_requests%ROWTYPE;
  v_reservation henvalt.email_usage_reservations%ROWTYPE;
  v_job henvalt.background_jobs%ROWTYPE;
  v_latest_generation integer;
  v_rows integer;
  v_reservation_found boolean := false;
BEGIN
  IF auth.role() IS DISTINCT FROM 'service_role' THEN
    RAISE EXCEPTION 'SERVICE_ROLE_REQUIRED' USING ERRCODE='42501';
  END IF;
  IF p_tenant_id IS NULL OR p_intervention_id IS NULL
     OR p_delivery_request_id IS NULL OR p_generation_number IS NULL OR p_generation_number NOT IN (2,3)
     OR p_retry_job_id IS NULL OR NULLIF(btrim(p_retry_worker_id),'') IS NULL THEN
    RAISE EXCEPTION 'DELIVERY_RETRY_ENVELOPE_FAILURE_IDENTITY_REQUIRED' USING ERRCODE='22023';
  END IF;

  SELECT * INTO v_intervention
    FROM henvalt.recovery_interventions
   WHERE id=p_intervention_id AND tenant_id=p_tenant_id
   FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'DELIVERY_INTERVENTION_NOT_FOUND'; END IF;
  IF v_intervention.delivery_frozen_at IS NOT NULL THEN
    RETURN jsonb_build_object('action','FROZEN','reason','INTERVENTION_DELIVERY_FROZEN');
  END IF;

  SELECT * INTO v_request
    FROM henvalt.delivery_requests
   WHERE id=p_delivery_request_id
     AND tenant_id=p_tenant_id
     AND intervention_id=p_intervention_id
     AND generation_number=p_generation_number
   FOR UPDATE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('action','STALE','reason','DELIVERY_RETRY_REQUEST_NOT_CURRENT');
  END IF;

  SELECT max(generation_number) INTO v_latest_generation
    FROM henvalt.delivery_requests
   WHERE tenant_id=p_tenant_id AND intervention_id=p_intervention_id;
  IF v_latest_generation IS DISTINCT FROM p_generation_number
     OR v_intervention.status <> 'SENDING'
     OR v_request.status <> 'PENDING'
     OR v_request.provider_claimed_at IS NOT NULL
     OR v_request.provider_egress_started_at IS NOT NULL
     OR EXISTS (
       SELECT 1 FROM henvalt.delivery_attempts da
        WHERE da.tenant_id=p_tenant_id
          AND da.delivery_request_id=p_delivery_request_id
     )
     OR EXISTS (
       SELECT 1 FROM henvalt.provider_events pe
        WHERE pe.tenant_id=p_tenant_id
          AND pe.delivery_request_id=p_delivery_request_id
     ) THEN
    RETURN jsonb_build_object('action','STALE','reason','DELIVERY_RETRY_REQUEST_NOT_FAILABLE');
  END IF;

  -- Read first without a child lock, then lock after reservation to preserve
  -- intervention -> request -> reservation -> background-job ordering.
  SELECT * INTO v_job
    FROM henvalt.background_jobs
   WHERE id=p_retry_job_id;
  IF NOT FOUND
     OR v_job.job_type <> 'execute_delivery_retry_generation'
     OR v_job.status <> 'CLAIMED'
     OR v_job.locked_by IS DISTINCT FROM p_retry_worker_id
     OR v_job.locked_at IS NULL
     OR v_job.locked_at < clock_timestamp()-interval '900 seconds'
     OR v_job.tenant_id IS DISTINCT FROM p_tenant_id
     OR v_job.payload->>'tenant_id' IS DISTINCT FROM p_tenant_id::text
     OR v_job.payload->>'intervention_id' IS DISTINCT FROM p_intervention_id::text
     OR v_job.payload->>'delivery_request_id' IS DISTINCT FROM p_delivery_request_id::text
     OR v_job.payload->>'generation_number' IS DISTINCT FROM p_generation_number::text
     OR NOT EXISTS (
       SELECT 1 FROM henvalt.delivery_retry_jobs rj
        WHERE rj.tenant_id=p_tenant_id
          AND rj.intervention_id=p_intervention_id
          AND rj.delivery_request_id=p_delivery_request_id
          AND rj.job_id=p_retry_job_id
     ) THEN
    RAISE EXCEPTION 'DELIVERY_RETRY_JOB_CLAIM_INVALID' USING ERRCODE='55000';
  END IF;

  SELECT * INTO v_reservation
    FROM henvalt.email_usage_reservations
   WHERE tenant_id=p_tenant_id AND delivery_request_id=p_delivery_request_id
   FOR UPDATE;
  v_reservation_found := FOUND;

  SELECT * INTO v_job
    FROM henvalt.background_jobs
   WHERE id=p_retry_job_id
   FOR UPDATE;
  IF NOT FOUND
     OR v_job.job_type <> 'execute_delivery_retry_generation'
     OR v_job.status <> 'CLAIMED'
     OR v_job.locked_by IS DISTINCT FROM p_retry_worker_id
     OR v_job.locked_at IS NULL
     OR v_job.locked_at < clock_timestamp()-interval '900 seconds'
     OR v_job.tenant_id IS DISTINCT FROM p_tenant_id
     OR v_job.payload->>'tenant_id' IS DISTINCT FROM p_tenant_id::text
     OR v_job.payload->>'intervention_id' IS DISTINCT FROM p_intervention_id::text
     OR v_job.payload->>'delivery_request_id' IS DISTINCT FROM p_delivery_request_id::text
     OR v_job.payload->>'generation_number' IS DISTINCT FROM p_generation_number::text
     OR NOT EXISTS (
       SELECT 1 FROM henvalt.delivery_retry_jobs rj
        WHERE rj.tenant_id=p_tenant_id
          AND rj.intervention_id=p_intervention_id
          AND rj.delivery_request_id=p_delivery_request_id
          AND rj.job_id=p_retry_job_id
     ) THEN
    RAISE EXCEPTION 'DELIVERY_RETRY_JOB_CLAIM_LOST' USING ERRCODE='55000';
  END IF;

  IF v_reservation_found AND v_reservation.status='RESERVED' THEN
    UPDATE henvalt.email_usage_reservations
       SET status='RELEASED',
           status_reason='DELIVERY_RETRY_ENVELOPE_INVALID',
           released_at=coalesce(released_at,clock_timestamp()),
           updated_at=clock_timestamp()
     WHERE id=v_reservation.id;
    GET DIAGNOSTICS v_rows=ROW_COUNT;
    IF v_rows=1 THEN
      INSERT INTO henvalt.email_usage_reservation_events(
        reservation_id,tenant_id,delivery_request_id,event_type,
        previous_status,new_status,delivery_attempt_id,provider_status_code,reason
      ) VALUES(
        v_reservation.id,p_tenant_id,p_delivery_request_id,'RELEASED',
        'RESERVED','RELEASED',NULL,NULL,'DELIVERY_RETRY_ENVELOPE_INVALID'
      );
    END IF;
  END IF;

  PERFORM henvalt.resolve_intervention_send_failure(
    p_intervention_id,'FAILED'::henvalt.intervention_status,
    'DELIVERY_RETRY_ENVELOPE_INVALID'
  );
  RETURN jsonb_build_object('action','FAILED','reason','DELIVERY_RETRY_ENVELOPE_INVALID');
END;
$function$;

REVOKE ALL ON FUNCTION henvalt.fail_delivery_retry_envelope_safely(uuid,uuid,uuid,integer,uuid,text)
  FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION henvalt.fail_delivery_retry_envelope_safely(uuid,uuid,uuid,integer,uuid,text)
  TO service_role;

COMMENT ON FUNCTION henvalt.fail_delivery_retry_envelope_safely(uuid,uuid,uuid,integer,uuid,text) IS
  'Fails a corrupt retry envelope only after exact tenant/request/generation/job ownership is revalidated under parent-first locks. Frozen or stale generations are no-ops; only a still-current PENDING generation may release its reservation and fail the intervention.';

-- A reclaimed retry can reuse its already-RESERVED quota hold. The normal
-- PENDING -> UNKNOWN billing trigger must not reserve the same request twice.
-- This early return is permitted only when no attempt, provider event or
-- provider-egress marker exists; the existing reservation continues to count.
DO $retry_quota_reuse_patch$
DECLARE
  v_oid regprocedure;
  v_definition text;
  v_patched text;
BEGIN
  v_oid := to_regprocedure('henvalt.enforce_billing_entitlement_before_delivery()');
  IF v_oid IS NULL THEN
    RAISE EXCEPTION 'RETRY_QUOTA_REUSE_BILLING_TRIGGER_MISSING';
  END IF;
  v_definition := pg_get_functiondef(v_oid);
  IF position('HENVALT_RETRY_RESERVED_HOLD_REUSE' IN v_definition) > 0 THEN
    RAISE EXCEPTION 'RETRY_QUOTA_REUSE_ALREADY_PATCHED';
  END IF;
  v_patched := regexp_replace(
    v_definition,
    'RAISE EXCEPTION ''HENVALT billing entitlement is not active; delivery denied''\s+USING ERRCODE = ''42501'';\s+END IF;',
    E'RAISE EXCEPTION ''HENVALT billing entitlement is not active; delivery denied''\n        USING ERRCODE = ''42501'';\n    END IF;\n\n  -- HENVALT_RETRY_RESERVED_HOLD_REUSE\n  IF OLD.status = ''PENDING'' AND NEW.status = ''UNKNOWN''\n     AND NEW.provider_egress_started_at IS NULL\n     AND EXISTS (SELECT 1 FROM henvalt.email_usage_reservations eur WHERE eur.tenant_id=NEW.tenant_id AND eur.delivery_request_id=NEW.id AND eur.status=''RESERVED'')\n     AND NOT EXISTS (SELECT 1 FROM henvalt.delivery_attempts da WHERE da.tenant_id=NEW.tenant_id AND da.delivery_request_id=NEW.id)\n     AND NOT EXISTS (SELECT 1 FROM henvalt.provider_events pe WHERE pe.tenant_id=NEW.tenant_id AND pe.delivery_request_id=NEW.id) THEN\n    RETURN NEW;\n  END IF;',
    'n'
  );
  IF v_patched = v_definition
     OR position('HENVALT_RETRY_RESERVED_HOLD_REUSE' IN v_patched) = 0 THEN
    RAISE EXCEPTION 'RETRY_QUOTA_REUSE_PATCH_ANCHOR_MISMATCH';
  END IF;
  EXECUTE v_patched;
END;
$retry_quota_reuse_patch$;

COMMIT;

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
     OR v_attempt.provider_response->>'henvalt_delivery_stage' <> 'pre_provider' THEN
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
     OR v_job.tenant_id IS DISTINCT FROM p_tenant_id
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
  IF NOT FOUND OR v_request.status <> 'PENDING'
     OR v_request.channel <> 'EMAIL'
     OR lower(COALESCE(v_request.provider,'')) <> 'mailersend'
     OR v_request.tracking_token IS NULL
     OR v_request.provider_claimed_at IS NOT NULL
     OR v_request.provider_egress_started_at IS NOT NULL
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

COMMIT;

\set ON_ERROR_STOP on
SET request.jwt.claim.role='service_role';

DO $test$
DECLARE
  v_tenant uuid := gen_random_uuid();
  v_intervention uuid := gen_random_uuid();
  v_request uuid := gen_random_uuid();
  v_job uuid := gen_random_uuid();
  v_retry_command uuid := gen_random_uuid();
  v_worker text := 'retry-authorize-worker';
  v_result jsonb;
BEGIN
  INSERT INTO henvalt.recovery_interventions(id,tenant_id,opportunity_id,channel,status)
  VALUES(v_intervention,v_tenant,gen_random_uuid(),'EMAIL','SENDING');

  INSERT INTO henvalt.delivery_requests(
    id,tenant_id,intervention_id,channel,delivery_mode,recipient_reference,
    status,provider,idempotency_key,correlation_id,generation_number
  ) VALUES(
    v_request,v_tenant,v_intervention,'EMAIL','HENVALT_MANAGED',
    'retry-authorize@example.test','PENDING','mailersend','retry-authorize-g2',
    gen_random_uuid(),2
  );

  INSERT INTO henvalt.background_jobs(
    id,tenant_id,job_type,payload,status,locked_by,locked_at
  ) VALUES(
    v_job,v_tenant,'execute_delivery_retry_generation',
    jsonb_build_object(
      'tenant_id',v_tenant,
      'intervention_id',v_intervention,
      'delivery_request_id',v_request,
      'generation_number',2
    ),
    'CLAIMED',v_worker,clock_timestamp()
  );

  INSERT INTO henvalt.delivery_retry_commands(
    tenant_id,intervention_id,retry_command_id,generation_number,delivery_request_id
  ) VALUES(v_tenant,v_intervention,v_retry_command,2,v_request);
  INSERT INTO henvalt.delivery_retry_jobs(
    tenant_id,intervention_id,retry_command_id,delivery_request_id,job_id
  ) VALUES(v_tenant,v_intervention,v_retry_command,v_request,v_job);

  v_result := henvalt.authorize_delivery_request_with_retry_lease(
    v_tenant,v_request,v_intervention,NULL,NULL,
    'retry-authorize@example.test','retry-authorize-g2',
    v_job,'stale-worker',2
  );
  IF v_result->>'can_send'<>'false' OR v_result->>'retry_job_claim_lost'<>'true' THEN
    RAISE EXCEPTION 'wrong retry worker was not rejected before request claim: %',v_result;
  END IF;
  IF (SELECT status::text FROM henvalt.delivery_requests WHERE id=v_request)<>'PENDING' THEN
    RAISE EXCEPTION 'wrong retry worker mutated delivery request before authorization';
  END IF;

  v_result := henvalt.authorize_delivery_request_with_retry_lease(
    v_tenant,v_request,v_intervention,NULL,NULL,
    'retry-authorize@example.test','retry-authorize-g2',
    v_job,v_worker,2
  );
  IF v_result->>'can_send'<>'true' THEN
    RAISE EXCEPTION 'current retry worker could not authorize delivery: %',v_result;
  END IF;
  IF (SELECT status::text FROM henvalt.delivery_requests WHERE id=v_request)<>'UNKNOWN' THEN
    RAISE EXCEPTION 'authorized retry request was not atomically claimed';
  END IF;
  IF (SELECT locked_at FROM henvalt.background_jobs WHERE id=v_job)
       < clock_timestamp()-interval '5 seconds' THEN
    RAISE EXCEPTION 'authorization did not refresh retry worker lease';
  END IF;
END;
$test$;

SELECT 'retry authorization lease gate acceptance passed' AS result;

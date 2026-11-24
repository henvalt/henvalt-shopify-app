\set ON_ERROR_STOP on
DO $tests$
DECLARE
  v_tenant uuid := gen_random_uuid();
  v_intervention uuid := gen_random_uuid();
  v_source_job uuid := gen_random_uuid();
  v_message uuid := gen_random_uuid();
  v_request uuid := gen_random_uuid();
  v_attempt uuid;
  v_result jsonb;
  v_retry_job uuid;
  v_retry_request uuid;
  v_generation integer;
  v_count integer;
  v_env record;

  v_tenant_amb uuid := gen_random_uuid();
  v_intervention_amb uuid := gen_random_uuid();
  v_job_amb uuid := gen_random_uuid();
  v_request_amb uuid := gen_random_uuid();
  v_attempt_amb uuid;

  v_tenant_max uuid := gen_random_uuid();
  v_intervention_max uuid := gen_random_uuid();
  v_job_max uuid := gen_random_uuid();
  v_request_max uuid := gen_random_uuid();
  v_attempt_max uuid;
BEGIN
  PERFORM set_config('request.jwt.claim.role','service_role',true);

  -- A normal intervention job with a server-proven pre-provider failure must
  -- atomically create generation 2, enqueue a dedicated retry job, and finish
  -- the original intervention job.
  INSERT INTO henvalt.recovery_interventions(id,tenant_id,opportunity_id,channel,status)
  VALUES(v_intervention,v_tenant,gen_random_uuid(),'EMAIL','FAILED');

  INSERT INTO henvalt.messages(
    id,tenant_id,intervention_id,channel,recipient,subject,body,tracking_token_id,rendered_at,metadata
  ) VALUES(
    v_message,v_tenant,v_intervention,'EMAIL','buyer@example.test',
    'Your cart is ready','<html><body><a href="https://tracking.example.test/t">Return</a><a href="https://unsubscribe.example.test/u">Unsubscribe</a></body></html>',
    gen_random_uuid(),now(),jsonb_build_object('unsubscribe_url','https://unsubscribe.example.test/u')
  );

  INSERT INTO henvalt.delivery_requests(
    id,tenant_id,intervention_id,recovery_id,opportunity_id,channel,delivery_mode,
    recipient_reference,message_reference,template_reference,tracking_token,
    status,provider,idempotency_key,correlation_id
  ) VALUES(
    v_request,v_tenant,v_intervention,gen_random_uuid(),gen_random_uuid(),'EMAIL',
    'HENVALT_MANAGED','buyer@example.test',v_message,'recovery-v1','tracking-token-1',
    'FAILED','mailersend','deliver:'||v_intervention::text,gen_random_uuid()
  );

  INSERT INTO henvalt.delivery_attempts(
    tenant_id,delivery_request_id,attempt_number,state,provider_status_code,provider_response
  ) VALUES(
    v_tenant,v_request,1,'FAILED',503,
    '{"henvalt_delivery_stage":"pre_provider","error":"delivery_preflight_failed"}'::jsonb
  ) RETURNING id INTO v_attempt;

  INSERT INTO henvalt.email_usage_reservations(
    tenant_id,delivery_request_id,status,status_reason,last_attempt_id
  ) VALUES(v_tenant,v_request,'RELEASED','PRE_PROVIDER_FAILURE',v_attempt);
  INSERT INTO henvalt.email_usage_reservation_events(
    reservation_id,tenant_id,delivery_request_id,event_type,previous_status,
    new_status,delivery_attempt_id,reason
  )
  SELECT id,v_tenant,v_request,'RELEASED','RESERVED','RELEASED',v_attempt,'PRE_PROVIDER_FAILURE'
    FROM henvalt.email_usage_reservations WHERE delivery_request_id=v_request;

  INSERT INTO henvalt.background_jobs(
    id,tenant_id,job_type,payload,status,locked_by
  ) VALUES(
    v_source_job,v_tenant,'execute_intervention',
    jsonb_build_object('tenant_id',v_tenant,'intervention_id',v_intervention),
    'CLAIMED','recovery-worker-1'
  );

  v_result := henvalt.enqueue_delivery_retry_generation_job(
    v_intervention,v_source_job,'recovery-worker-1',v_request,v_attempt
  );
  IF v_result->>'action'<>'RETRY_QUEUED' THEN
    RAISE EXCEPTION 'expected RETRY_QUEUED, got %',v_result;
  END IF;
  v_retry_job := (v_result->>'retry_job_id')::uuid;
  v_retry_request := (v_result->>'delivery_request_id')::uuid;
  v_generation := (v_result->>'generation_number')::integer;

  IF v_generation<>2 THEN RAISE EXCEPTION 'expected generation 2, got %',v_generation; END IF;
  IF (SELECT status::text FROM henvalt.background_jobs WHERE id=v_source_job)<>'SUCCEEDED' THEN
    RAISE EXCEPTION 'source intervention job was not completed atomically';
  END IF;
  IF (SELECT status::text FROM henvalt.background_jobs WHERE id=v_retry_job)<>'QUEUED' THEN
    RAISE EXCEPTION 'retry generation job was not queued';
  END IF;
  IF (SELECT job_type FROM henvalt.background_jobs WHERE id=v_retry_job)<>'execute_delivery_retry_generation' THEN
    RAISE EXCEPTION 'wrong retry job type';
  END IF;
  IF (SELECT payload->>'delivery_request_id' FROM henvalt.background_jobs WHERE id=v_retry_job)<>v_retry_request::text THEN
    RAISE EXCEPTION 'retry job is not bound to exact new delivery request';
  END IF;
  IF (SELECT message_reference FROM henvalt.delivery_requests WHERE id=v_retry_request)<>v_message
     OR (SELECT tracking_token FROM henvalt.delivery_requests WHERE id=v_retry_request)<>'tracking-token-1' THEN
    RAISE EXCEPTION 'retry generation did not preserve the immutable message envelope';
  END IF;

  -- The retry worker must claim the exact job and load the persisted envelope;
  -- it must not regenerate or substitute message content.
  UPDATE henvalt.background_jobs
     SET status='CLAIMED',locked_by='delivery-worker-2',locked_at=now()
   WHERE id=v_retry_job;
  SELECT * INTO v_env
    FROM henvalt.load_delivery_retry_envelope(
      v_retry_job,'delivery-worker-2',v_tenant,v_intervention,v_retry_request,2
    );
  IF v_env.delivery_request_id<>v_retry_request
     OR v_env.message_id<>v_message
     OR v_env.recipient<>'buyer@example.test'
     OR v_env.subject<>'Your cart is ready'
     OR v_env.html_body NOT LIKE '%tracking.example.test%'
     OR v_env.html_body NOT LIKE '%unsubscribe.example.test%'
     OR NULLIF(btrim(v_env.text_body),'') IS NULL
     OR v_env.tracking_token<>'tracking-token-1' THEN
    RAISE EXCEPTION 'loaded retry envelope does not match the original immutable message';
  END IF;

  BEGIN
    PERFORM * FROM henvalt.load_delivery_retry_envelope(
      v_retry_job,'wrong-worker',v_tenant,v_intervention,v_retry_request,2
    );
    RAISE EXCEPTION 'wrong worker loaded a delivery retry envelope';
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM='wrong worker loaded a delivery retry envelope' THEN RAISE; END IF;
    IF SQLERRM<>'DELIVERY_RETRY_JOB_CLAIM_INVALID' THEN RAISE; END IF;
  END;

  UPDATE henvalt.recovery_interventions
     SET delivery_frozen_at=clock_timestamp(),delivery_freeze_reason='TEST_FROZEN_RETRY_PARENT'
   WHERE id=v_intervention;
  SELECT count(*) INTO v_count
    FROM henvalt.load_delivery_retry_envelope(
      v_retry_job,'delivery-worker-2',v_tenant,v_intervention,v_retry_request,2
    );
  IF v_count<>0 THEN RAISE EXCEPTION 'frozen intervention exposed a retry envelope'; END IF;

  -- Ambiguous/provider-side evidence is not a retry. It remains held and does
  -- not create another generation or a retry job.
  INSERT INTO henvalt.recovery_interventions(id,tenant_id,opportunity_id,channel,status)
  VALUES(v_intervention_amb,v_tenant_amb,gen_random_uuid(),'EMAIL','FAILED');
  INSERT INTO henvalt.delivery_requests(
    id,tenant_id,intervention_id,channel,delivery_mode,recipient_reference,
    status,provider,idempotency_key,correlation_id
  ) VALUES(
    v_request_amb,v_tenant_amb,v_intervention_amb,'EMAIL','HENVALT_MANAGED',
    'ambiguous@example.test','FAILED','mailersend','ambiguous-key',gen_random_uuid()
  );
  INSERT INTO henvalt.delivery_attempts(
    tenant_id,delivery_request_id,attempt_number,state,provider_status_code,provider_response
  ) VALUES(
    v_tenant_amb,v_request_amb,1,'UNKNOWN',503,
    '{"henvalt_delivery_stage":"provider_response","error":"provider_transport_ambiguous"}'::jsonb
  ) RETURNING id INTO v_attempt_amb;
  INSERT INTO henvalt.email_usage_reservations(
    tenant_id,delivery_request_id,status,status_reason,last_attempt_id
  ) VALUES(v_tenant_amb,v_request_amb,'CONSUMED','AMBIGUOUS_PROVIDER_OUTCOME',v_attempt_amb);
  INSERT INTO henvalt.background_jobs(
    id,tenant_id,job_type,payload,status,locked_by
  ) VALUES(
    v_job_amb,v_tenant_amb,'execute_intervention',
    jsonb_build_object('tenant_id',v_tenant_amb,'intervention_id',v_intervention_amb),
    'CLAIMED','recovery-worker-amb'
  );
  BEGIN
    PERFORM henvalt.enqueue_delivery_retry_generation_job(
      v_intervention_amb,v_job_amb,'recovery-worker-amb',v_request_amb,gen_random_uuid()
    );
    RAISE EXCEPTION 'mismatched attempt identity was accepted';
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM='mismatched attempt identity was accepted' THEN RAISE; END IF;
    IF SQLERRM<>'DELIVERY_RETRY_EXPECTED_ATTEMPT_STALE' THEN RAISE; END IF;
  END;
  v_result := henvalt.enqueue_delivery_retry_generation_job(
    v_intervention_amb,v_job_amb,'recovery-worker-amb'
  );
  IF v_result->>'action'<>'CONTINUE_NORMAL' THEN
    RAISE EXCEPTION 'ambiguous provider outcome incorrectly queued retry: %',v_result;
  END IF;
  IF (SELECT count(*) FROM henvalt.delivery_requests WHERE intervention_id=v_intervention_amb)<>1 THEN
    RAISE EXCEPTION 'ambiguous provider outcome created another generation';
  END IF;

  -- Generation 3 is the hard ceiling. A further pre-provider failure is
  -- terminally dead-lettered instead of generating an unbounded retry chain.
  INSERT INTO henvalt.recovery_interventions(id,tenant_id,opportunity_id,channel,status)
  VALUES(v_intervention_max,v_tenant_max,gen_random_uuid(),'EMAIL','FAILED');
  INSERT INTO henvalt.delivery_requests(
    id,tenant_id,intervention_id,channel,delivery_mode,recipient_reference,
    status,provider,idempotency_key,correlation_id,generation_number
  ) VALUES(
    v_request_max,v_tenant_max,v_intervention_max,'EMAIL','HENVALT_MANAGED',
    'max@example.test','FAILED','mailersend','generation-three-key',gen_random_uuid(),3
  );
  INSERT INTO henvalt.delivery_attempts(
    tenant_id,delivery_request_id,attempt_number,state,provider_status_code,provider_response
  ) VALUES(
    v_tenant_max,v_request_max,1,'FAILED',409,
    '{"henvalt_delivery_stage":"pre_provider","error":"sender_not_configured"}'::jsonb
  ) RETURNING id INTO v_attempt_max;
  INSERT INTO henvalt.email_usage_reservations(
    tenant_id,delivery_request_id,status,status_reason,last_attempt_id
  ) VALUES(v_tenant_max,v_request_max,'RELEASED','PRE_PROVIDER_FAILURE',v_attempt_max);
  INSERT INTO henvalt.email_usage_reservation_events(
    reservation_id,tenant_id,delivery_request_id,event_type,previous_status,
    new_status,delivery_attempt_id,reason
  )
  SELECT id,v_tenant_max,v_request_max,'RELEASED','RESERVED','RELEASED',v_attempt_max,'PRE_PROVIDER_FAILURE'
    FROM henvalt.email_usage_reservations WHERE delivery_request_id=v_request_max;
  INSERT INTO henvalt.background_jobs(
    id,tenant_id,job_type,payload,status,locked_by
  ) VALUES(
    v_job_max,v_tenant_max,'execute_delivery_retry_generation',
    jsonb_build_object('tenant_id',v_tenant_max,'intervention_id',v_intervention_max,
      'delivery_request_id',v_request_max,'generation_number',3),
    'CLAIMED','recovery-worker-max'
  );
  v_result := henvalt.enqueue_delivery_retry_generation_job(
    v_tenant_max,v_intervention_max,v_job_max,'recovery-worker-max'
  );
  IF v_result->>'action'<>'DEAD_LETTER' THEN
    RAISE EXCEPTION 'generation limit did not dead-letter retry job: %',v_result;
  END IF;
  IF (SELECT status::text FROM henvalt.background_jobs WHERE id=v_job_max)<>'DEAD_LETTER' THEN
    RAISE EXCEPTION 'generation limit did not terminally dead-letter source job';
  END IF;
  IF (SELECT count(*) FROM henvalt.delivery_requests WHERE intervention_id=v_intervention_max)<>1 THEN
    RAISE EXCEPTION 'generation limit created an extra request';
  END IF;
END;
$tests$;

SELECT 'delivery retry generation job and immutable envelope acceptance passed' AS result;

\set ON_ERROR_STOP on
SET request.jwt.claim.role='service_role';

DO $test$
DECLARE
  v_tenant uuid := 'f1000000-0000-4000-8000-000000000001';
  v_intervention uuid := 'f2000000-0000-4000-8000-000000000001';
  v_request uuid := 'f3000000-0000-4000-8000-000000000001';
  v_message uuid := 'f5000000-0000-4000-8000-000000000001';
  v_job uuid := 'f4000000-0000-4000-8000-000000000001';
  v_retry_command uuid := 'f6000000-0000-4000-8000-000000000001';
  v_worker text := 'retry-egress-worker';
  v_result boolean;
  v_marker timestamptz;
BEGIN
  INSERT INTO henvalt.recovery_interventions(id,tenant_id,opportunity_id,channel,status)
  VALUES(v_intervention,v_tenant,gen_random_uuid(),'EMAIL','SENDING');
  INSERT INTO henvalt.billing_accounts(
    tenant_id,status,test_mode,activated_at,monthly_email_limit
  ) VALUES(v_tenant,'ACTIVE',false,clock_timestamp(),1000);

  INSERT INTO henvalt.delivery_requests(
    id,tenant_id,intervention_id,channel,delivery_mode,recipient_reference,
    message_reference,tracking_token,status,provider,idempotency_key,correlation_id,generation_number
  ) VALUES(
    v_request,v_tenant,v_intervention,'EMAIL','HENVALT_MANAGED',
    'retry-egress@example.test',v_message,'retry-egress-tracking','PENDING','mailersend','retry-egress-g2',
    gen_random_uuid(),2
  );

  INSERT INTO henvalt.messages(
    id,tenant_id,intervention_id,channel,recipient,subject,body,rendered_at
  ) VALUES(
    v_message,v_tenant,v_intervention,'EMAIL','retry-egress@example.test',
    'Stored retry subject','<p>Stored retry body</p>',clock_timestamp()
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

  -- The envelope loader itself must reject an expired claim and return the
  -- exact persisted message only while the retry worker lease is fresh.
  UPDATE henvalt.background_jobs
     SET locked_at=clock_timestamp()-interval '901 seconds'
   WHERE id=v_job;
  BEGIN
    PERFORM * FROM henvalt.load_delivery_retry_envelope(
      v_job,v_worker,v_tenant,v_intervention,v_request,2
    );
    RAISE EXCEPTION 'expired retry worker loaded the stored envelope';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM='expired retry worker loaded the stored envelope' THEN RAISE; END IF;
    IF SQLERRM<>'DELIVERY_RETRY_JOB_CLAIM_INVALID' THEN RAISE; END IF;
  END;
  UPDATE henvalt.background_jobs SET locked_at=clock_timestamp() WHERE id=v_job;
  IF (SELECT count(*) FROM henvalt.load_delivery_retry_envelope(
        v_job,v_worker,v_tenant,v_intervention,v_request,2
      ))<>1 THEN
    RAISE EXCEPTION 'fresh retry worker could not load the immutable message envelope';
  END IF;

  -- An expired 15-minute lease must not be renewed by the previous worker.
  UPDATE henvalt.background_jobs
     SET locked_at=clock_timestamp()-interval '901 seconds'
   WHERE id=v_job;
  BEGIN
    PERFORM henvalt.renew_delivery_retry_job_lease(
      v_tenant,v_request,v_job,v_worker,2
    );
    RAISE EXCEPTION 'expired retry lease was renewed';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM='expired retry lease was renewed' THEN RAISE; END IF;
    IF SQLERRM<>'DELIVERY_RETRY_JOB_CLAIM_INVALID' THEN RAISE; END IF;
  END;

  -- A fresh lease still cannot be used by a different worker identity.
  UPDATE henvalt.background_jobs SET locked_at=clock_timestamp() WHERE id=v_job;
  BEGIN
    PERFORM henvalt.renew_delivery_retry_job_lease(
      v_tenant,v_request,v_job,'different-worker',2
    );
    RAISE EXCEPTION 'wrong retry worker renewed lease';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM='wrong retry worker renewed lease' THEN RAISE; END IF;
    IF SQLERRM<>'DELIVERY_RETRY_JOB_CLAIM_INVALID' THEN RAISE; END IF;
  END;

  v_result := henvalt.renew_delivery_retry_job_lease(
    v_tenant,v_request,v_job,v_worker,2
  );
  IF v_result IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'current retry worker could not renew its lease';
  END IF;
  IF (SELECT locked_at FROM henvalt.background_jobs WHERE id=v_job)
       < clock_timestamp()-interval '5 seconds' THEN
    RAISE EXCEPTION 'retry lease heartbeat did not refresh locked_at';
  END IF;

  -- Simulate the credential RPC's request claim. The final egress boundary
  -- must recheck the exact retry worker after this state transition.
  UPDATE henvalt.delivery_requests
     SET status='UNKNOWN',provider_claimed_at=clock_timestamp()
   WHERE id=v_request;

  BEGIN
    PERFORM henvalt.mark_mailersend_provider_egress_started(
      v_tenant,v_request,v_job,'different-worker',2
    );
    RAISE EXCEPTION 'wrong retry worker crossed provider egress';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM='wrong retry worker crossed provider egress' THEN RAISE; END IF;
    IF SQLERRM<>'DELIVERY_RETRY_JOB_CLAIM_INVALID' THEN RAISE; END IF;
  END;

  v_result := henvalt.mark_mailersend_provider_egress_started(
    v_tenant,v_request,v_job,v_worker,2
  );
  IF v_result IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'current retry worker did not cross provider egress';
  END IF;
  SELECT provider_egress_started_at INTO v_marker
    FROM henvalt.delivery_requests WHERE id=v_request;
  IF v_marker IS NULL THEN RAISE EXCEPTION 'retry egress marker was not persisted'; END IF;

  -- The one-way egress marker prevents a second crossing even with a valid job.
  BEGIN
    PERFORM henvalt.mark_mailersend_provider_egress_started(
      v_tenant,v_request,v_job,v_worker,2
    );
    RAISE EXCEPTION 'retry generation crossed provider egress twice';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM='retry generation crossed provider egress twice' THEN RAISE; END IF;
    IF SQLERRM<>'DELIVERY_RETRY_GENERATION_NOT_SENDABLE' THEN RAISE; END IF;
  END;
END;
$test$;

SELECT 'retry job lease heartbeat and final provider-egress ownership acceptance passed' AS result;

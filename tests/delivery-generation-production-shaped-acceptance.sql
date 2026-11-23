\set ON_ERROR_STOP on
DO $tests$
DECLARE
  v_tenant uuid := gen_random_uuid();
  v_intervention uuid := gen_random_uuid();
  v_request uuid := gen_random_uuid();
  v_command uuid := gen_random_uuid();
  v_next uuid;
  v_same uuid;
  v_gen integer;
  v_status text;
  v_count integer;
  v_attempt uuid;
BEGIN
  PERFORM set_config('request.jwt.claim.role','service_role',true);

  INSERT INTO henvalt.recovery_interventions(id,tenant_id,opportunity_id,channel,status)
  VALUES(v_intervention,v_tenant,gen_random_uuid(),'EMAIL','FAILED');

  INSERT INTO henvalt.delivery_requests(
    id,tenant_id,intervention_id,recovery_id,opportunity_id,channel,delivery_mode,
    recipient_reference,message_reference,template_reference,tracking_token,
    status,provider,idempotency_key,correlation_id,provider_claimed_at
  ) VALUES (
    v_request,v_tenant,v_intervention,gen_random_uuid(),gen_random_uuid(),'EMAIL',
    'HENVALT_MANAGED','buyer@example.test',gen_random_uuid(),'recovery-v1',
    'track-token-1','FAILED','mailersend','legacy-intervention-key',gen_random_uuid(),now()
  );

  INSERT INTO henvalt.delivery_attempts(
    tenant_id,delivery_request_id,attempt_number,state,provider_status_code,provider_response
  ) VALUES (
    v_tenant,v_request,1,'FAILED',409,
    '{"henvalt_delivery_stage":"pre_provider","error":"credential_unavailable"}'::jsonb
  ) RETURNING id INTO v_attempt;

  INSERT INTO henvalt.email_usage_reservations(
    tenant_id,delivery_request_id,status,status_reason,last_attempt_id
  ) VALUES (
    v_tenant,v_request,'RELEASED','DEFINITIVE_PROVIDER_REJECTION_409',v_attempt
  );
  INSERT INTO henvalt.email_usage_reservation_events(reservation_id,tenant_id,delivery_request_id,event_type,previous_status,new_status,delivery_attempt_id,reason)
  SELECT id,v_tenant,v_request,'RELEASED','RESERVED','RELEASED',v_attempt,'DEFINITIVE_PROVIDER_REJECTION_409'
  FROM henvalt.email_usage_reservations WHERE delivery_request_id=v_request;

  -- Existing row is generation 1 without changing its identity or state.
  SELECT generation_number,status::text INTO v_gen,v_status
    FROM henvalt.delivery_requests WHERE id=v_request;
  IF v_gen<>1 OR v_status<>'FAILED' THEN
    RAISE EXCEPTION 'existing request backfill changed identity/state';
  END IF;

  v_next := henvalt.create_delivery_retry_generation(v_tenant,v_intervention,v_command);
  IF v_next IS NULL OR v_next=v_request THEN
    RAISE EXCEPTION 'retry generation did not create a distinct request';
  END IF;

  SELECT generation_number,status::text INTO v_gen,v_status
    FROM henvalt.delivery_requests WHERE id=v_next;
  IF v_gen<>2 OR v_status<>'PENDING' THEN
    RAISE EXCEPTION 'new request generation/status incorrect: %, %',v_gen,v_status;
  END IF;

  SELECT count(*) INTO v_count FROM henvalt.delivery_retry_commands
   WHERE tenant_id=v_tenant AND intervention_id=v_intervention
     AND retry_command_id=v_command AND delivery_request_id=v_next;
  IF v_count<>1 THEN RAISE EXCEPTION 'retry command ledger missing'; END IF;

  v_same := henvalt.create_delivery_retry_generation(v_tenant,v_intervention,v_command);
  IF v_same IS DISTINCT FROM v_next THEN
    RAISE EXCEPTION 'same retry command did not return same request';
  END IF;

  IF (SELECT status::text FROM henvalt.delivery_requests WHERE id=v_request)<>'FAILED' THEN
    RAISE EXCEPTION 'prior generation was mutated';
  END IF;
  IF (SELECT count(*) FROM henvalt.email_usage_reservations WHERE delivery_request_id=v_next)<>0 THEN
    RAISE EXCEPTION 'generation creation pre-created quota reservation';
  END IF;
  IF (SELECT status::text FROM henvalt.recovery_interventions WHERE id=v_intervention)<>'SENDING' THEN
    RAISE EXCEPTION 'parent intervention not returned to SENDING';
  END IF;

  BEGIN
    UPDATE henvalt.delivery_requests SET generation_number=99 WHERE id=v_next;
    RAISE EXCEPTION 'generation number mutation was accepted';
  EXCEPTION WHEN SQLSTATE '55000' THEN NULL;
  END;


  BEGIN
    UPDATE henvalt.delivery_retry_commands SET generation_number=99
     WHERE tenant_id=v_tenant AND intervention_id=v_intervention AND retry_command_id=v_command;
    RAISE EXCEPTION 'retry ledger mutation was accepted';
  EXCEPTION WHEN SQLSTATE '55000' THEN NULL;
  END;

  -- A second distinct retry command cannot fork a still-pending generation.
  BEGIN
    PERFORM henvalt.create_delivery_retry_generation(v_tenant,v_intervention,gen_random_uuid());
    RAISE EXCEPTION 'pending generation was forked';
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM='pending generation was forked' THEN RAISE; END IF;
  END;

  -- The routine must reject non-service callers.
  PERFORM set_config('request.jwt.claim.role','authenticated',true);
  BEGIN
    PERFORM henvalt.create_delivery_retry_generation(v_tenant,v_intervention,gen_random_uuid());
    RAISE EXCEPTION 'authenticated caller created generation';
  EXCEPTION WHEN insufficient_privilege THEN
    NULL;
  END;
  PERFORM set_config('request.jwt.claim.role','service_role',true);
END
$tests$;

SELECT 'production-shaped delivery generation migration acceptance passed' AS result;

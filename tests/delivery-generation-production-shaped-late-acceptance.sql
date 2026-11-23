\\set ON_ERROR_STOP on
SET request.jwt.claim.role='service_role';

DO $test$
DECLARE
  v_tenant uuid := 'd1000000-0000-4000-8000-000000000001';
  v_parent uuid := 'd2000000-0000-4000-8000-000000000001';
  v_old uuid := 'd3000000-0000-4000-8000-000000000001';
  v_new uuid := 'd3000000-0000-4000-8000-000000000002';
  v_event uuid := 'd4000000-0000-4000-8000-000000000001';
  v_normal_parent uuid := 'd2000000-0000-4000-8000-000000000002';
  v_normal_request uuid := 'd3000000-0000-4000-8000-000000000003';
  v_normal_event uuid := 'd4000000-0000-4000-8000-000000000002';
  v_bad_event uuid := 'd4000000-0000-4000-8000-000000000003';
  v_result boolean;
  v_before_attempts integer;
  v_after_attempts integer;
BEGIN
  INSERT INTO henvalt.recovery_interventions(id,tenant_id,opportunity_id,channel,status)
  VALUES(v_parent,v_tenant,gen_random_uuid(),'EMAIL','SENDING');
  INSERT INTO henvalt.delivery_requests(
    id,tenant_id,intervention_id,channel,delivery_mode,recipient_reference,
    status,provider,provider_message_id,idempotency_key,generation_number
  ) VALUES
    (v_old,v_tenant,v_parent,'EMAIL','HENVALT_MANAGED','recipient-old','FAILED','mailersend','msg-old','old-g1',1),
    (v_new,v_tenant,v_parent,'EMAIL','HENVALT_MANAGED','recipient-new','PENDING','mailersend',NULL,'new-g2',2);
  INSERT INTO henvalt.delivery_attempts(
    tenant_id,delivery_request_id,attempt_number,state,provider_status_code,provider_response
  ) VALUES(v_tenant,v_old,1,'FAILED',503,'{"provider":"timeout"}'::jsonb);
  INSERT INTO henvalt.email_usage_reservations(
    tenant_id,delivery_request_id,cycle_start,status,status_reason,released_at
  ) VALUES(v_tenant,v_old,now(),'RELEASED','PRE_PROVIDER_FAILURE',now());

  INSERT INTO henvalt.provider_events(
    id,provider,event_hash,event_type,provider_message_id,tenant_id,
    delivery_request_id,payload
  ) VALUES(
    v_event,'mailersend','late-event-hash-1','activity.delivered','msg-old',v_tenant,
    v_old,jsonb_build_object('type','activity.delivered','data',jsonb_build_object(
      'message_id','msg-old','tags',jsonb_build_array('tenant:'||v_tenant::text,'delivery:'||v_old::text)
    ))
  );

  SELECT count(*) INTO v_before_attempts FROM henvalt.delivery_attempts WHERE delivery_request_id=v_old;
  v_result := henvalt.settle_late_provider_acceptance(v_event);
  IF v_result IS DISTINCT FROM true THEN RAISE EXCEPTION 'late acceptance not classified'; END IF;
  IF NOT EXISTS (
    SELECT 1 FROM henvalt.recovery_interventions
     WHERE id=v_parent AND delivery_frozen_at IS NOT NULL
       AND delivery_freeze_reason='LATE_PROVIDER_ACCEPTANCE'
  ) THEN RAISE EXCEPTION 'parent intervention not frozen'; END IF;
  IF NOT EXISTS (
    SELECT 1 FROM henvalt.delivery_generation_incidents
     WHERE provider_event_id=v_event AND delivery_request_id=v_old
       AND incident_type='LATE_PROVIDER_ACCEPTANCE'
  ) THEN RAISE EXCEPTION 'append-only incident not recorded'; END IF;
  IF (SELECT status FROM henvalt.email_usage_reservations WHERE delivery_request_id=v_old) <> 'CONSUMED' THEN
    RAISE EXCEPTION 'released quota reservation not consumed by late acceptance';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM henvalt.email_usage_reservation_events
     WHERE delivery_request_id=v_old AND event_type='CONSUMED'
       AND previous_status='RELEASED' AND reason='LATE_PROVIDER_ACCEPTANCE'
       AND delivery_attempt_id IS NULL
  ) THEN RAISE EXCEPTION 'late acceptance quota evidence missing'; END IF;
  SELECT count(*) INTO v_after_attempts FROM henvalt.delivery_attempts WHERE delivery_request_id=v_old;
  IF v_after_attempts <> v_before_attempts THEN
    RAISE EXCEPTION 'historical delivery attempts were rewritten or fabricated';
  END IF;
  IF henvalt.settle_late_provider_acceptance(v_event) IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'duplicate late acceptance was not idempotent';
  END IF;
  IF (SELECT count(*) FROM henvalt.delivery_generation_incidents WHERE provider_event_id=v_event) <> 1 THEN
    RAISE EXCEPTION 'duplicate incident inserted';
  END IF;

  INSERT INTO henvalt.recovery_interventions(id,tenant_id,opportunity_id,channel,status)
  VALUES(v_normal_parent,v_tenant,gen_random_uuid(),'EMAIL','SENDING');
  INSERT INTO henvalt.delivery_requests(
    id,tenant_id,intervention_id,channel,delivery_mode,recipient_reference,
    status,provider,provider_message_id,idempotency_key,generation_number
  ) VALUES(v_normal_request,v_tenant,v_normal_parent,'EMAIL','HENVALT_MANAGED','recipient-normal',
    'ACCEPTED','mailersend','msg-normal','normal-g1',1);
  INSERT INTO henvalt.provider_events(
    id,provider,event_hash,event_type,provider_message_id,tenant_id,
    delivery_request_id,payload
  ) VALUES(v_normal_event,'mailersend','normal-event-hash','activity.sent','msg-normal',v_tenant,
    v_normal_request,jsonb_build_object('type','activity.sent','data',jsonb_build_object(
      'message_id','msg-normal','tags',jsonb_build_array('tenant:'||v_tenant::text,'delivery:'||v_normal_request::text)
    )));
  IF henvalt.settle_late_provider_acceptance(v_normal_event) IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'current accepted generation incorrectly classified as late';
  END IF;
  IF EXISTS (SELECT 1 FROM henvalt.recovery_interventions WHERE id=v_normal_parent AND delivery_frozen_at IS NOT NULL) THEN
    RAISE EXCEPTION 'normal first-generation acceptance froze parent';
  END IF;

  INSERT INTO henvalt.provider_events(
    id,provider,event_hash,event_type,provider_message_id,tenant_id,
    delivery_request_id,payload
  ) VALUES(v_bad_event,'mailersend','bad-event-hash','activity.delivered','msg-normal',v_tenant,
    v_normal_request,jsonb_build_object('type','activity.delivered','data',jsonb_build_object(
      'message_id','msg-normal','tags',jsonb_build_array('tenant:'||v_tenant::text,'delivery:'||v_old::text)
    )));
  BEGIN
    PERFORM henvalt.settle_late_provider_acceptance(v_bad_event);
    RAISE EXCEPTION 'mismatched delivery tag was accepted';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM='mismatched delivery tag was accepted' THEN RAISE; END IF;
    IF SQLERRM NOT LIKE '%PROVIDER_EVENT_TAG_IDENTITY_CONFLICT%' THEN RAISE; END IF;
  END;

  IF has_function_privilege('anon','henvalt.settle_late_provider_acceptance(uuid)','EXECUTE')
     OR has_function_privilege('authenticated','henvalt.settle_late_provider_acceptance(uuid)','EXECUTE') THEN
    RAISE EXCEPTION 'untrusted role can execute late acceptance settlement';
  END IF;
END;
$test$;

SELECT 'late provider acceptance production-shaped acceptance passed' AS result;

\set ON_ERROR_STOP on
SET request.jwt.claim.role='service_role';

DO $test$
DECLARE
  v_tenant uuid := 'd5000000-0000-4000-8000-000000000001';
  v_parent uuid := 'd6000000-0000-4000-8000-000000000001';
  v_old uuid := 'd7000000-0000-4000-8000-000000000001';
  v_new uuid := 'd7000000-0000-4000-8000-000000000002';
  v_normal_parent uuid := 'd6000000-0000-4000-8000-000000000002';
  v_normal uuid := 'd7000000-0000-4000-8000-000000000003';
  v_result jsonb;
  v_attempts integer;
BEGIN
  INSERT INTO henvalt.recovery_interventions(id,tenant_id,opportunity_id,channel,status)
  VALUES(v_parent,v_tenant,gen_random_uuid(),'EMAIL','SENDING'),
        (v_normal_parent,v_tenant,gen_random_uuid(),'EMAIL','SENDING');
  INSERT INTO henvalt.delivery_requests(
    id,tenant_id,intervention_id,channel,delivery_mode,recipient_reference,
    status,provider,provider_message_id,idempotency_key,generation_number
  ) VALUES
    (v_old,v_tenant,v_parent,'EMAIL','HENVALT_MANAGED','old-recipient','FAILED','mailersend','msg-old','old-g1',1),
    (v_new,v_tenant,v_parent,'EMAIL','HENVALT_MANAGED','new-recipient','PENDING','mailersend',NULL,'new-g2',2),
    (v_normal,v_tenant,v_normal_parent,'EMAIL','HENVALT_MANAGED','normal-recipient','UNKNOWN','mailersend',NULL,'normal-g1',1);
  INSERT INTO henvalt.delivery_attempts(
    tenant_id,delivery_request_id,attempt_number,state,provider_status_code,provider_response
  ) VALUES(v_tenant,v_old,1,'FAILED',503,'{"error":"transport ambiguity"}'::jsonb);
  SELECT count(*) INTO v_attempts FROM henvalt.delivery_attempts WHERE delivery_request_id=v_old;

  v_result := henvalt.process_mailersend_webhook_event(
    jsonb_build_object('type','activity.delivered','data',jsonb_build_object(
      'message_id','msg-old','email','old@example.test',
      'tags',jsonb_build_array('tenant:'||v_tenant::text,'delivery:'||v_old::text)
    )),
    'raw-late-delivered-001'
  );
  IF v_result->>'accepted' <> 'true' THEN RAISE EXCEPTION 'late webhook not accepted'; END IF;
  IF NOT EXISTS (
    SELECT 1 FROM henvalt.recovery_interventions
     WHERE id=v_parent AND delivery_frozen_at IS NOT NULL
       AND delivery_freeze_reason='LATE_PROVIDER_ACCEPTANCE'
  ) THEN RAISE EXCEPTION 'late webhook did not freeze parent'; END IF;
  IF NOT EXISTS (
    SELECT 1 FROM henvalt.delivery_generation_incidents
     WHERE delivery_request_id=v_old AND incident_type='LATE_PROVIDER_ACCEPTANCE'
  ) THEN RAISE EXCEPTION 'late webhook incident missing'; END IF;
  IF (SELECT status FROM henvalt.delivery_requests WHERE id=v_old) <> 'FAILED' THEN
    RAISE EXCEPTION 'late webhook rewrote historical failed request';
  END IF;
  IF (SELECT count(*) FROM henvalt.delivery_attempts WHERE delivery_request_id=v_old) <> v_attempts THEN
    RAISE EXCEPTION 'late webhook fabricated or rewrote a delivery attempt';
  END IF;

  v_result := henvalt.process_mailersend_webhook_event(
    jsonb_build_object('type','activity.delivered','data',jsonb_build_object(
      'message_id','msg-old','email','old@example.test',
      'tags',jsonb_build_array('tenant:'||v_tenant::text,'delivery:'||v_old::text)
    )),
    'raw-late-delivered-001'
  );
  IF v_result->>'duplicate' <> 'true' THEN RAISE EXCEPTION 'duplicate webhook not idempotent'; END IF;
  IF (SELECT count(*) FROM henvalt.delivery_generation_incidents WHERE delivery_request_id=v_old) <> 1 THEN
    RAISE EXCEPTION 'duplicate webhook created duplicate incident';
  END IF;

  v_result := henvalt.process_mailersend_webhook_event(
    jsonb_build_object('type','activity.sent','data',jsonb_build_object(
      'message_id','msg-normal','email','normal@example.test',
      'tags',jsonb_build_array('tenant:'||v_tenant::text,'delivery:'||v_normal::text)
    )),
    'raw-normal-sent-002'
  );
  IF (SELECT status FROM henvalt.delivery_requests WHERE id=v_normal) <> 'ACCEPTED' THEN
    RAISE EXCEPTION 'normal activity.sent did not settle current generation to ACCEPTED';
  END IF;
  IF (SELECT provider_message_id FROM henvalt.delivery_requests WHERE id=v_normal) <> 'msg-normal' THEN
    RAISE EXCEPTION 'message id not bound through exact delivery tag';
  END IF;
  IF EXISTS (SELECT 1 FROM henvalt.recovery_interventions WHERE id=v_normal_parent AND delivery_frozen_at IS NOT NULL) THEN
    RAISE EXCEPTION 'normal activity.sent incorrectly froze current generation';
  END IF;

  BEGIN
    PERFORM henvalt.process_mailersend_webhook_event(
      jsonb_build_object('type','activity.delivered','data',jsonb_build_object(
        'message_id','msg-normal','email','normal@example.test',
        'tags',jsonb_build_array('tenant:'||v_tenant::text,'delivery:'||v_old::text)
      )),
      'raw-mismatched-delivery-tag-003'
    );
    RAISE EXCEPTION 'mismatched delivery tag was accepted';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM='mismatched delivery tag was accepted' THEN RAISE; END IF;
    IF SQLERRM NOT LIKE '%Provider event is not yet linked%' THEN RAISE; END IF;
  END;
END;
$test$;

SELECT 'MailerSend exact-tag webhook routing acceptance passed' AS result;

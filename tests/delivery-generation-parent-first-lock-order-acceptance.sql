\set ON_ERROR_STOP on
DO $assert$
DECLARE
  v_tenant uuid := 'a1a1a1a1-a1a1-41a1-81a1-a1a1a1a1a1a1';
  v_intervention uuid := 'b2b2b2b2-b2b2-42b2-82b2-b2b2b2b2b2b2';
  v_request uuid := 'c3c3c3c3-c3c3-43c3-83c3-c3c3c3c3c3c3';
  v_def text;
  v_parent integer;
  v_child integer;
  v_result jsonb;
BEGIN
  INSERT INTO henvalt.recovery_interventions(id,tenant_id,opportunity_id,channel,status)
  VALUES(v_intervention,v_tenant,gen_random_uuid(),'EMAIL','SENDING');
  INSERT INTO henvalt.delivery_requests(
    id,tenant_id,intervention_id,channel,delivery_mode,status,provider,
    opportunity_id,recipient_reference,idempotency_key,message_reference
  ) VALUES(
    v_request,v_tenant,v_intervention,'EMAIL','HENVALT_MANAGED','PENDING','mailersend',
    gen_random_uuid(),'parent-first@example.test','parent-first-key',gen_random_uuid()
  );

  v_def := pg_get_functiondef('henvalt.authorize_delivery_request(uuid,uuid,uuid,uuid,uuid,text,text)'::regprocedure);
  v_parent := position('PERFORM 1 FROM henvalt.recovery_interventions WHERE id = p_intervention_id' in v_def);
  v_child := position('SELECT * INTO v_request FROM henvalt.delivery_requests' in v_def);
  IF v_parent=0 OR v_child=0 OR v_parent>=v_child THEN
    RAISE EXCEPTION 'authorization parent-first lock order missing';
  END IF;

  v_def := pg_get_functiondef('henvalt.get_mailersend_token_for_delivery(uuid,uuid)'::regprocedure);
  v_parent := position('PERFORM 1 FROM henvalt.recovery_interventions ri' in v_def);
  v_child := position('UPDATE henvalt.delivery_requests dr' in v_def);
  IF v_parent=0 OR v_child=0 OR v_parent>=v_child THEN
    RAISE EXCEPTION 'token parent-first lock order missing';
  END IF;

  v_def := pg_get_functiondef('henvalt.record_delivery_result(uuid,text,text,integer,henvalt.delivery_state,text,boolean,jsonb)'::regprocedure);
  v_parent := position('PERFORM 1 FROM henvalt.recovery_interventions WHERE id = v_intervention_id' in v_def);
  v_child := position('SELECT tenant_id, intervention_id, status INTO v_tenant_id' in v_def);
  IF v_parent=0 OR v_child=0 OR v_parent>=v_child THEN
    RAISE EXCEPTION 'result parent-first lock order missing';
  END IF;

  v_def := pg_get_functiondef('henvalt.process_mailersend_webhook_event(jsonb,text)'::regprocedure);
  IF position('FOR UPDATE' in v_def)>0 THEN
    RAISE EXCEPTION 'webhook still locks child before result settlement';
  END IF;

  v_result := henvalt.authorize_delivery_request(
    v_tenant,v_request,v_intervention,NULL,NULL,'parent-first@example.test','parent-first-key'
  );
  IF v_result->>'can_send'<>'true' THEN RAISE EXCEPTION 'authorization fixture call failed: %',v_result; END IF;
  IF (SELECT status::text FROM henvalt.delivery_requests WHERE id=v_request)<>'UNKNOWN' THEN
    RAISE EXCEPTION 'authorization did not claim request';
  END IF;
  IF henvalt.get_mailersend_token_for_delivery(v_tenant,v_request)<>'token' THEN
    RAISE EXCEPTION 'token fixture call failed';
  END IF;
  PERFORM henvalt.record_delivery_result(
    v_request,'mailersend','parent-first-message',202,'DELIVERED',NULL,false,'{}'::jsonb
  );
  IF (henvalt.process_mailersend_webhook_event(
    jsonb_build_object('tenant_id',v_tenant,'message_id','parent-first-message'),'eA=='
  )->>'matched')<>'true' THEN
    RAISE EXCEPTION 'webhook fixture call failed';
  END IF;
END;
$assert$;

SELECT 'delivery lifecycle parent-first lock order acceptance passed' AS result;

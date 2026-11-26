\set ON_ERROR_STOP on
SELECT henvalt.set_provider_sending_enabled(true, 'lock-order acceptance test');

DO $assert$
DECLARE
  v_tenant uuid := 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
  v_intervention uuid := 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';
  v_request uuid := 'cccccccc-cccc-4ccc-8ccc-cccccccccccc';
  v_def text;
  v_parent integer;
  v_child integer;
BEGIN
  INSERT INTO henvalt.recovery_interventions(id,tenant_id) VALUES(v_intervention,v_tenant);
  INSERT INTO henvalt.delivery_requests(id,tenant_id,intervention_id,status,provider,provider_message_id)
  VALUES(v_request,v_tenant,v_intervention,'UNKNOWN','mailersend','msg-1');

  v_def := pg_get_functiondef('henvalt.authorize_delivery_request(uuid,uuid,uuid,uuid,uuid,text,text)'::regprocedure);
  v_parent := position('PERFORM 1 FROM henvalt.recovery_interventions WHERE id = p_intervention_id' in v_def);
  v_child := position('SELECT * INTO v_request FROM henvalt.delivery_requests' in v_def);
  IF v_parent=0 OR v_child=0 OR v_parent>=v_child THEN RAISE EXCEPTION 'authorization parent-first lock order missing'; END IF;

  v_def := pg_get_functiondef('henvalt.get_mailersend_token_for_delivery_legacy_v1(uuid,uuid)'::regprocedure);
  v_parent := position('PERFORM 1 FROM henvalt.recovery_interventions ri' in v_def);
  v_child := position('UPDATE henvalt.delivery_requests dr' in v_def);
  IF v_parent=0 OR v_child=0 OR v_parent>=v_child THEN RAISE EXCEPTION 'token parent-first lock order missing'; END IF;

  v_def := pg_get_functiondef('henvalt.record_delivery_result(uuid,text,text,integer,henvalt.delivery_state,text,boolean,jsonb)'::regprocedure);
  v_parent := position('PERFORM 1 FROM henvalt.recovery_interventions WHERE id = v_intervention_id' in v_def);
  v_child := position('SELECT tenant_id, intervention_id, status INTO v_tenant_id' in v_def);
  IF v_parent=0 OR v_child=0 OR v_parent>=v_child THEN RAISE EXCEPTION 'result parent-first lock order missing'; END IF;

  v_def := pg_get_functiondef('henvalt.process_mailersend_webhook_event(jsonb,text)'::regprocedure);
  IF position('FOR UPDATE' in v_def)>0 THEN RAISE EXCEPTION 'webhook still locks child before result settlement'; END IF;

  IF henvalt.authorize_delivery_request(v_tenant,v_request,v_intervention,NULL,NULL,NULL,NULL)->>'can_send' <> 'true' THEN
    RAISE EXCEPTION 'authorization fixture call failed';
  END IF;
  IF henvalt.get_mailersend_token_for_delivery(v_tenant,v_request) <> 'token' THEN
    RAISE EXCEPTION 'token fixture call failed';
  END IF;
  PERFORM henvalt.record_delivery_result(v_request,'mailersend','msg-1',200,'DELIVERED',NULL,false,'{}'::jsonb);
  IF (henvalt.process_mailersend_webhook_event(jsonb_build_object('tenant_id',v_tenant,'message_id','msg-1'),'eA==')->>'matched') <> 'true' THEN
    RAISE EXCEPTION 'webhook fixture call failed';
  END IF;
END;
$assert$;

SELECT henvalt.set_provider_sending_enabled(false, 'close after lock-order acceptance test');

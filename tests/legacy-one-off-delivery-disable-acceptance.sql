\set ON_ERROR_STOP on
SELECT henvalt.set_provider_sending_enabled(true, 'legacy one-off disable acceptance test');

DO $assert$
DECLARE
  v_def text;
  v_tenant uuid := 'e1e1e1e1-e1e1-41e1-81e1-e1e1e1e1e1e1';
  v_intervention uuid := 'e2e2e2e2-e2e2-42e2-82e2-e2e2e2e2e2e2';
  v_request uuid := 'e3e3e3e3-e3e3-43e3-83e3-e3e3e3e3e3e3';
  v_rejected boolean := false;
BEGIN
  v_def := pg_get_functiondef('henvalt.get_mailersend_token_for_delivery_legacy_v1(uuid,uuid)'::regprocedure);
  IF position('6d769024-cd44-4da4-be1d-a25a3dca0660' IN v_def)>0
     OR position('henvalt-one-off-email-test-2026-11-14-v1' IN v_def)>0
     OR position('urmuhammadrehan18@gmail.com' IN v_def)>0 THEN
    RAISE EXCEPTION 'hard-coded one-off token allowlist survived cutover patch';
  END IF;

  v_def := pg_get_functiondef('henvalt.reauthorize_one_off_test_delivery(uuid,text)'::regprocedure);
  IF position('LEGACY_ONE_OFF_DELIVERY_DISABLED_FOR_IMMUTABLE_GENERATIONS' IN v_def)=0 THEN
    RAISE EXCEPTION 'legacy reauthorization RPC was not disabled';
  END IF;
  IF has_function_privilege('service_role','henvalt.reauthorize_one_off_test_delivery(uuid,text)','EXECUTE') THEN
    RAISE EXCEPTION 'service_role can still execute legacy reauthorization RPC';
  END IF;

  v_def := pg_get_functiondef('henvalt.prepare_one_off_test_delivery(uuid,text)'::regprocedure);
  IF position('LEGACY_ONE_OFF_DELIVERY_DISABLED_FOR_IMMUTABLE_GENERATIONS' IN v_def)=0 THEN
    RAISE EXCEPTION 'legacy preparation RPC was not disabled';
  END IF;
  IF has_function_privilege('service_role','henvalt.prepare_one_off_test_delivery(uuid,text)','EXECUTE') THEN
    RAISE EXCEPTION 'service_role can still execute legacy preparation RPC';
  END IF;

  INSERT INTO henvalt.recovery_interventions(id,tenant_id) VALUES(v_intervention,v_tenant);
  INSERT INTO henvalt.delivery_requests(
    id,tenant_id,intervention_id,status,provider,opportunity_id,recipient_reference,idempotency_key,message_reference
  ) VALUES(v_request,v_tenant,v_intervention,'UNKNOWN','mailersend',gen_random_uuid(),'normal@example.test','normal-key',gen_random_uuid());

  IF henvalt.get_mailersend_token_for_delivery(v_tenant,v_request) <> 'token' THEN
    RAISE EXCEPTION 'normal tenant-scoped token claim was broken by allowlist removal';
  END IF;

  BEGIN
    PERFORM henvalt.reauthorize_one_off_test_delivery(v_request,'normal@example.test');
  EXCEPTION WHEN SQLSTATE '55000' THEN
    v_rejected := true;
  END;
  IF NOT v_rejected THEN RAISE EXCEPTION 'legacy one-off reauthorization did not fail closed'; END IF;

  v_rejected := false;
  BEGIN
    PERFORM henvalt.prepare_one_off_test_delivery(gen_random_uuid(),'normal@example.test');
  EXCEPTION WHEN SQLSTATE '55000' THEN
    v_rejected := true;
  END;
  IF NOT v_rejected THEN RAISE EXCEPTION 'legacy one-off preparation did not fail closed'; END IF;
END;
$assert$;

SELECT henvalt.set_provider_sending_enabled(false, 'close after legacy one-off disable acceptance test');

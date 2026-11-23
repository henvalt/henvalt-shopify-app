-- Reconcile the four deployed delivery lifecycle RPCs around one lock order:
-- recovery_interventions (parent) -> delivery_requests (child).
-- This is a candidate-only source-preserving patch: pg_get_functiondef is
-- rewritten with guarded, narrowly-scoped substitutions so unrelated policy
-- checks and historical business logic remain byte-for-byte intact.
-- Do not apply to production before staging verification and explicit approval.

BEGIN;

DO $patch$
DECLARE
  v_oid regprocedure;
  v_definition text;
  v_patched text;
BEGIN
  -- 1) Authorization: acquire the intervention row before the request row.
  v_oid := to_regprocedure(
    'henvalt.authorize_delivery_request(uuid,uuid,uuid,uuid,uuid,text,text)'
  );
  IF v_oid IS NULL THEN
    RAISE EXCEPTION 'DELIVERY_LOCK_ORDER_AUTHORIZATION_RPC_MISSING';
  END IF;
  v_definition := pg_get_functiondef(v_oid);
  IF position('PERFORM 1 FROM henvalt.recovery_interventions WHERE id = p_intervention_id' IN v_definition) > 0 THEN
    RAISE EXCEPTION 'DELIVERY_LOCK_ORDER_AUTHORIZATION_ALREADY_PATCHED';
  END IF;
  v_patched := regexp_replace(
    v_definition,
    'SELECT \* INTO v_request FROM henvalt\.delivery_requests\s+WHERE id = p_delivery_request_id AND tenant_id = p_tenant_id FOR UPDATE;',
    E'PERFORM 1 FROM henvalt.recovery_interventions WHERE id = p_intervention_id AND tenant_id = p_tenant_id FOR UPDATE;\n  IF NOT FOUND THEN RETURN jsonb_build_object(''can_send'', false, ''reason'', ''INTERVENTION_NOT_SENDABLE''); END IF;\n\n  SELECT * INTO v_request FROM henvalt.delivery_requests WHERE id = p_delivery_request_id AND tenant_id = p_tenant_id FOR UPDATE;',
    'n'
  );
  IF v_patched = v_definition OR position('PERFORM 1 FROM henvalt.recovery_interventions WHERE id = p_intervention_id' IN v_patched) = 0 THEN
    RAISE EXCEPTION 'DELIVERY_LOCK_ORDER_AUTHORIZATION_PATCH_ANCHOR_MISMATCH';
  END IF;
  EXECUTE v_patched;

  -- 2) Token claim: derive the parent id without locking the child, then lock
  -- parent before the UPDATE acquires the delivery_requests row lock.
  v_oid := to_regprocedure(
    'henvalt.get_mailersend_token_for_delivery(uuid,uuid)'
  );
  IF v_oid IS NULL THEN
    RAISE EXCEPTION 'DELIVERY_LOCK_ORDER_TOKEN_RPC_MISSING';
  END IF;
  v_definition := pg_get_functiondef(v_oid);
  IF position('PERFORM 1 FROM henvalt.recovery_interventions ri WHERE ri.id = (SELECT dr.intervention_id' IN v_definition) > 0 THEN
    RAISE EXCEPTION 'DELIVERY_LOCK_ORDER_TOKEN_ALREADY_PATCHED';
  END IF;
  v_patched := regexp_replace(
    v_definition,
    'UPDATE henvalt\.delivery_requests dr\s+SET provider_claimed_at = clock_timestamp\(\),\s+updated_at = now\(\)\s+WHERE dr\.id = p_delivery_request_id',
    E'PERFORM 1 FROM henvalt.recovery_interventions ri WHERE ri.id = (SELECT dr.intervention_id FROM henvalt.delivery_requests dr WHERE dr.id = p_delivery_request_id AND dr.tenant_id = p_tenant_id) AND ri.tenant_id = p_tenant_id FOR UPDATE;\n  IF NOT FOUND THEN RAISE EXCEPTION ''DELIVERY_INTERVENTION_NOT_FOUND''; END IF;\n\n  UPDATE henvalt.delivery_requests dr SET provider_claimed_at = clock_timestamp(), updated_at = now() WHERE dr.id = p_delivery_request_id',
    'n'
  );
  IF v_patched = v_definition OR position('PERFORM 1 FROM henvalt.recovery_interventions ri WHERE ri.id = (SELECT dr.intervention_id' IN v_patched) = 0 THEN
    RAISE EXCEPTION 'DELIVERY_LOCK_ORDER_TOKEN_PATCH_ANCHOR_MISMATCH';
  END IF;
  EXECUTE v_patched;

  -- 3) Result recording: read the request's parent key without a row lock,
  -- lock the parent, then retain the original authoritative child FOR UPDATE.
  v_oid := to_regprocedure(
    'henvalt.record_delivery_result(uuid,text,text,integer,henvalt.delivery_state,text,boolean,jsonb)'
  );
  IF v_oid IS NULL THEN
    RAISE EXCEPTION 'DELIVERY_LOCK_ORDER_RESULT_RPC_MISSING';
  END IF;
  v_definition := pg_get_functiondef(v_oid);
  IF position('PERFORM 1 FROM henvalt.recovery_interventions WHERE id = v_intervention_id' IN v_definition) > 0 THEN
    RAISE EXCEPTION 'DELIVERY_LOCK_ORDER_RESULT_ALREADY_PATCHED';
  END IF;
  v_patched := regexp_replace(
    v_definition,
    'SELECT\s+tenant_id,\s+intervention_id,\s+status\s+INTO\s+v_tenant_id,\s+v_intervention_id,\s+v_current_state\s+FROM henvalt\.delivery_requests\s+WHERE id = p_delivery_request_id\s+FOR UPDATE;',
    E'SELECT tenant_id, intervention_id INTO v_tenant_id, v_intervention_id FROM henvalt.delivery_requests WHERE id = p_delivery_request_id;\n  IF NOT FOUND THEN RAISE EXCEPTION ''Delivery request not found: %'', p_delivery_request_id; END IF;\n  PERFORM 1 FROM henvalt.recovery_interventions WHERE id = v_intervention_id AND tenant_id = v_tenant_id FOR UPDATE;\n  IF NOT FOUND THEN RAISE EXCEPTION ''Delivery intervention not found: %'', v_intervention_id; END IF;\n\n  SELECT tenant_id, intervention_id, status INTO v_tenant_id, v_intervention_id, v_current_state FROM henvalt.delivery_requests WHERE id = p_delivery_request_id FOR UPDATE;',
    'n'
  );
  IF v_patched = v_definition OR position('PERFORM 1 FROM henvalt.recovery_interventions WHERE id = v_intervention_id' IN v_patched) = 0 THEN
    RAISE EXCEPTION 'DELIVERY_LOCK_ORDER_RESULT_PATCH_ANCHOR_MISMATCH';
  END IF;
  EXECUTE v_patched;

  -- 4) Webhook lookup must not lock the child before it delegates state
  -- settlement to record_delivery_result (which now takes parent -> child).
  v_oid := to_regprocedure(
    'henvalt.process_mailersend_webhook_event(jsonb,text)'
  );
  IF v_oid IS NULL THEN
    RAISE EXCEPTION 'DELIVERY_LOCK_ORDER_WEBHOOK_RPC_MISSING';
  END IF;
  v_definition := pg_get_functiondef(v_oid);
  IF position('SELECT dr.id INTO v_req' IN v_definition) = 0
     OR v_definition !~ 'LIMIT 1\\s+FOR UPDATE;' THEN
    RAISE EXCEPTION 'DELIVERY_LOCK_ORDER_WEBHOOK_EXPECTED_LOCK_NOT_FOUND';
  END IF;
  v_patched := regexp_replace(
    v_definition,
    '(LIMIT 1)\s+FOR UPDATE;',
    E'\\1;',
    'n'
  );
  IF v_patched = v_definition THEN
    RAISE EXCEPTION 'DELIVERY_LOCK_ORDER_WEBHOOK_PATCH_FAILED';
  END IF;
  EXECUTE v_patched;
END;
$patch$;

COMMIT;

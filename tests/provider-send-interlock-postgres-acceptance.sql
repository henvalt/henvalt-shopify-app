\set ON_ERROR_STOP on

DO $acceptance$
DECLARE
  v_id uuid;
  v_role text;
  v_events integer;
BEGIN
  IF henvalt.provider_sending_is_enabled() IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'default interlock is not closed';
  END IF;

  FOREACH v_role IN ARRAY ARRAY['anon', 'authenticated', 'service_role'] LOOP
    IF has_table_privilege(v_role, 'henvalt.provider_send_control', 'SELECT')
       OR has_table_privilege(v_role, 'henvalt.provider_send_control', 'UPDATE')
       OR has_table_privilege(v_role, 'henvalt.provider_send_control_events', 'SELECT')
       OR has_table_privilege(v_role, 'henvalt.provider_send_control_events', 'INSERT')
       OR has_function_privilege(v_role, 'henvalt.provider_sending_is_enabled()', 'EXECUTE')
       OR has_function_privilege(v_role, 'henvalt.set_provider_sending_enabled(boolean,text)', 'EXECUTE')
       OR has_function_privilege(v_role, 'henvalt.enforce_provider_send_interlock()', 'EXECUTE') THEN
      RAISE EXCEPTION 'application role % has unexpected interlock privileges', v_role;
    END IF;
  END LOOP;

  BEGIN
    INSERT INTO henvalt.delivery_requests(status) VALUES ('UNKNOWN');
    RAISE EXCEPTION 'expected direct UNKNOWN insert to be blocked';
  EXCEPTION WHEN insufficient_privilege THEN
    IF SQLERRM <> 'HENVALT_PROVIDER_SENDING_DISABLED' THEN RAISE; END IF;
  END;

  INSERT INTO henvalt.delivery_requests(status) VALUES ('PENDING') RETURNING id INTO v_id;
  BEGIN
    UPDATE henvalt.delivery_requests SET status = 'UNKNOWN' WHERE id = v_id;
    RAISE EXCEPTION 'expected PENDING to UNKNOWN transition to be blocked';
  EXCEPTION WHEN insufficient_privilege THEN
    IF SQLERRM <> 'HENVALT_PROVIDER_SENDING_DISABLED' THEN RAISE; END IF;
  END;

  BEGIN
    UPDATE henvalt.delivery_requests SET provider_claimed_at = now() WHERE id = v_id;
    RAISE EXCEPTION 'expected provider credential claim to be blocked';
  EXCEPTION WHEN insufficient_privilege THEN
    IF SQLERRM <> 'HENVALT_PROVIDER_SENDING_DISABLED' THEN RAISE; END IF;
  END;

  PERFORM henvalt.set_provider_sending_enabled(true, 'synthetic PostgreSQL staging integration test');
  INSERT INTO henvalt.delivery_requests(status) VALUES ('UNKNOWN') RETURNING id INTO v_id;
  UPDATE henvalt.delivery_requests SET provider_claimed_at = now() WHERE id = v_id;

  PERFORM henvalt.set_provider_sending_enabled(false, 'close after synthetic staging integration test');
  IF henvalt.provider_sending_is_enabled() IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'interlock did not close after operator change';
  END IF;

  DELETE FROM henvalt.provider_send_control WHERE control_key = 'global';
  IF henvalt.provider_sending_is_enabled() IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'missing control row did not fail closed';
  END IF;

  SELECT count(*) INTO v_events FROM henvalt.provider_send_control_events;
  IF v_events <> 2 THEN
    RAISE EXCEPTION 'expected two operator audit events, got %', v_events;
  END IF;
END
$acceptance$;

SELECT 'provider-send interlock PostgreSQL acceptance passed' AS result;

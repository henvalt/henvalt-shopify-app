\set ON_ERROR_STOP on
DO $test$
DECLARE
  t uuid := '11111111-1111-4111-8111-111111111111';
  r1 uuid := '22222222-2222-4222-8222-222222222221';
  r2 uuid := '22222222-2222-4222-8222-222222222222';
  r3 uuid := '22222222-2222-4222-8222-222222222223';
  n integer;
BEGIN
  INSERT INTO henvalt.billing_accounts(tenant_id,status,test_mode,activated_at,monthly_email_limit)
  VALUES(t,'PENDING',true,now()-interval '1 day',5);
  INSERT INTO henvalt.email_usage_measurements(tenant_id,delivery_attempt_id)
  SELECT t, gen_random_uuid() FROM generate_series(1,4);
  INSERT INTO henvalt.delivery_requests(id,tenant_id) VALUES(r1,t),(r2,t),(r3,t);

  UPDATE henvalt.delivery_requests SET status='UNKNOWN' WHERE id=r1;
  IF (SELECT status FROM henvalt.email_usage_reservations WHERE delivery_request_id=r1) <> 'RESERVED' THEN
    RAISE EXCEPTION 'claim did not create a reserved quota hold';
  END IF;
  UPDATE henvalt.delivery_requests SET status='UNKNOWN' WHERE id=r1;
  SELECT count(*) INTO n FROM henvalt.email_usage_reservations WHERE delivery_request_id=r1;
  IF n <> 1 THEN RAISE EXCEPTION 'repeated state update created duplicate reservation'; END IF;

  -- Four measured units plus one outstanding reservation exhaust the cap.
  BEGIN
    UPDATE henvalt.delivery_requests SET status='UNKNOWN' WHERE id=r2;
    RAISE EXCEPTION 'reservation was not counted against the final quota slot';
  EXCEPTION WHEN insufficient_privilege THEN
    IF SQLERRM NOT LIKE 'HENVALT email usage limit reached%' THEN RAISE; END IF;
  END;
  IF (SELECT status FROM henvalt.delivery_requests WHERE id=r2) <> 'PENDING' THEN
    RAISE EXCEPTION 'denied quota claim changed request state';
  END IF;

  INSERT INTO henvalt.delivery_attempts(id,tenant_id,delivery_request_id,state,provider_status_code)
  VALUES(gen_random_uuid(),t,r1,'FAILED',400);
  IF (SELECT status FROM henvalt.email_usage_reservations WHERE delivery_request_id=r1) <> 'RELEASED' THEN
    RAISE EXCEPTION 'definitive provider rejection did not release reservation';
  END IF;

  -- Releasing a definitive rejection makes the slot available again.
  UPDATE henvalt.delivery_requests SET status='UNKNOWN' WHERE id=r2;
  INSERT INTO henvalt.delivery_attempts(id,tenant_id,delivery_request_id,state,provider_status_code)
  VALUES(gen_random_uuid(),t,r2,'UNKNOWN',502);
  IF (SELECT status FROM henvalt.email_usage_reservations WHERE delivery_request_id=r2) <> 'CONSUMED' THEN
    RAISE EXCEPTION 'ambiguous provider result did not consume reservation';
  END IF;
  SELECT count(*) INTO n FROM henvalt.email_usage_measurements WHERE tenant_id=t;
  IF n <> 5 THEN RAISE EXCEPTION 'ambiguous attempt not measured exactly once: %',n; END IF;

  -- A late provider acceptance overrides an earlier release and is measured.
  INSERT INTO henvalt.delivery_attempts(id,tenant_id,delivery_request_id,state,provider_status_code)
  VALUES(gen_random_uuid(),t,r1,'ACCEPTED',202);
  IF (SELECT status FROM henvalt.email_usage_reservations WHERE delivery_request_id=r1) <> 'CONSUMED' THEN
    RAISE EXCEPTION 'late acceptance did not consume released reservation';
  END IF;
  SELECT count(*) INTO n FROM henvalt.email_usage_measurements WHERE tenant_id=t;
  IF n <> 6 THEN RAISE EXCEPTION 'late acceptance was not measured exactly once: %',n; END IF;

  BEGIN
    UPDATE henvalt.delivery_requests SET status='UNKNOWN' WHERE id=r3;
    RAISE EXCEPTION 'quota cap allowed an additional email after late acceptance';
  EXCEPTION WHEN insufficient_privilege THEN
    IF SQLERRM NOT LIKE 'HENVALT email usage limit reached%' THEN RAISE; END IF;
  END;

  -- A 429 response is not proof of non-acceptance and must retain its hold.
  INSERT INTO henvalt.billing_accounts(tenant_id,status,test_mode,activated_at,monthly_email_limit)
  VALUES('33333333-3333-4333-8333-333333333333','PENDING',true,now()-interval '1 day',10);
  INSERT INTO henvalt.delivery_requests(id,tenant_id)
  VALUES('44444444-4444-4444-8444-444444444441','33333333-3333-4333-8333-333333333333');
  UPDATE henvalt.delivery_requests SET status='UNKNOWN'
   WHERE id='44444444-4444-4444-8444-444444444441';
  INSERT INTO henvalt.delivery_attempts(id,tenant_id,delivery_request_id,state,provider_status_code)
  VALUES(gen_random_uuid(),'33333333-3333-4333-8333-333333333333',
    '44444444-4444-4444-8444-444444444441','FAILED',429);
  IF (SELECT status FROM henvalt.email_usage_reservations
       WHERE delivery_request_id='44444444-4444-4444-8444-444444444441') <> 'RESERVED' THEN
    RAISE EXCEPTION '429 rate limit incorrectly released quota reservation';
  END IF;

  IF (SELECT count(*) FROM henvalt.email_usage_reservation_events WHERE tenant_id=t) <> 5 THEN
    RAISE EXCEPTION 'reservation state history missing transitions';
  END IF;
  IF has_table_privilege('anon','henvalt.email_usage_reservations','SELECT')
     OR has_table_privilege('authenticated','henvalt.email_usage_reservations','SELECT')
     OR has_table_privilege('service_role','henvalt.email_usage_reservations','SELECT')
     OR has_table_privilege('anon','henvalt.email_usage_reservation_events','SELECT')
     OR has_table_privilege('authenticated','henvalt.email_usage_reservation_events','SELECT')
     OR has_table_privilege('service_role','henvalt.email_usage_reservation_events','SELECT') THEN
    RAISE EXCEPTION 'email reservation or event table is exposed to application roles';
  END IF;
  BEGIN
    UPDATE henvalt.email_usage_reservation_events SET reason='tamper attempt';
    RAISE EXCEPTION 'reservation event history was mutable';
  EXCEPTION WHEN SQLSTATE '55000' THEN
    NULL;
  END;
  BEGIN
    DELETE FROM henvalt.email_usage_reservation_events;
    RAISE EXCEPTION 'reservation event history was deletable';
  EXCEPTION WHEN SQLSTATE '55000' THEN
    NULL;
  END;

  -- Timeouts, conflicts, rate limits and 5xx responses are not proof of rejection.
  INSERT INTO henvalt.billing_accounts(tenant_id,status,test_mode,activated_at,monthly_email_limit)
  VALUES('77777777-7777-4777-8777-777777777777','PENDING',true,now()-interval '1 day',20);
  INSERT INTO henvalt.delivery_requests(id,tenant_id) VALUES
    ('88888888-8888-4888-8888-888888888801','77777777-7777-4777-8777-777777777777'),
    ('88888888-8888-4888-8888-888888888802','77777777-7777-4777-8777-777777777777'),
    ('88888888-8888-4888-8888-888888888803','77777777-7777-4777-8777-777777777777'),
    ('88888888-8888-4888-8888-888888888804','77777777-7777-4777-8777-777777777777'),
    ('88888888-8888-4888-8888-888888888805','77777777-7777-4777-8777-777777777777'),
    ('88888888-8888-4888-8888-888888888806','77777777-7777-4777-8777-777777777777');
  UPDATE henvalt.delivery_requests SET status='UNKNOWN'
   WHERE tenant_id='77777777-7777-4777-8777-777777777777';
  INSERT INTO henvalt.delivery_attempts(id,tenant_id,delivery_request_id,state,provider_status_code)
  VALUES
    (gen_random_uuid(),'77777777-7777-4777-8777-777777777777','88888888-8888-4888-8888-888888888801','FAILED',408),
    (gen_random_uuid(),'77777777-7777-4777-8777-777777777777','88888888-8888-4888-8888-888888888802','FAILED',409),
    (gen_random_uuid(),'77777777-7777-4777-8777-777777777777','88888888-8888-4888-8888-888888888803','FAILED',429),
    (gen_random_uuid(),'77777777-7777-4777-8777-777777777777','88888888-8888-4888-8888-888888888804','FAILED',500),
    (gen_random_uuid(),'77777777-7777-4777-8777-777777777777','88888888-8888-4888-8888-888888888805','FAILED',502),
    (gen_random_uuid(),'77777777-7777-4777-8777-777777777777','88888888-8888-4888-8888-888888888806','FAILED',503);
  IF EXISTS (
    SELECT 1 FROM henvalt.email_usage_reservations
     WHERE tenant_id='77777777-7777-4777-8777-777777777777'
       AND status <> 'RESERVED'
  ) THEN
    RAISE EXCEPTION 'timeout/conflict/rate-limit/server-error incorrectly released quota';
  END IF;

  -- Missing provider status remains held; UNKNOWN is itself ambiguous even
  -- when a response code happens to look like a client error.
  INSERT INTO henvalt.delivery_requests(id,tenant_id)
  VALUES
    ('88888888-8888-4888-8888-888888888807','77777777-7777-4777-8777-777777777777'),
    ('88888888-8888-4888-8888-888888888808','77777777-7777-4777-8777-777777777777');
  UPDATE henvalt.delivery_requests SET status='UNKNOWN'
   WHERE id IN (
     '88888888-8888-4888-8888-888888888807',
     '88888888-8888-4888-8888-888888888808'
   );
  INSERT INTO henvalt.delivery_attempts(id,tenant_id,delivery_request_id,state,provider_status_code)
  VALUES
    (gen_random_uuid(),'77777777-7777-4777-8777-777777777777','88888888-8888-4888-8888-888888888807','FAILED',NULL),
    (gen_random_uuid(),'77777777-7777-4777-8777-777777777777','88888888-8888-4888-8888-888888888808','UNKNOWN',400);
  IF (SELECT status FROM henvalt.email_usage_reservations
       WHERE delivery_request_id='88888888-8888-4888-8888-888888888807') <> 'RESERVED' THEN
    RAISE EXCEPTION 'missing provider status incorrectly released quota';
  END IF;
  IF (SELECT status FROM henvalt.email_usage_reservations
       WHERE delivery_request_id='88888888-8888-4888-8888-888888888808') <> 'CONSUMED' THEN
    RAISE EXCEPTION 'UNKNOWN provider result did not consume quota';
  END IF;


  -- A later definitive rejection cannot release a reservation already consumed
  -- by an earlier accepted/ambiguous attempt for this delivery request.
  INSERT INTO henvalt.delivery_attempts(id,tenant_id,delivery_request_id,state,provider_status_code)
  VALUES(gen_random_uuid(),t,r2,'FAILED',400);
  IF (SELECT status FROM henvalt.email_usage_reservations WHERE delivery_request_id=r2) <> 'CONSUMED' THEN
    RAISE EXCEPTION 'later definitive rejection downgraded a consumed reservation';
  END IF;
  IF (SELECT count(*) FROM henvalt.email_usage_reservation_events
       WHERE delivery_request_id=r2 AND new_status='RELEASED') <> 0 THEN
    RAISE EXCEPTION 'later rejection appended a release event after acceptance';
  END IF;

  -- Exercise every member of the narrow definitive-rejection allowlist.
  INSERT INTO henvalt.billing_accounts(tenant_id,status,test_mode,activated_at,monthly_email_limit)
  VALUES('99999999-9999-4999-8999-999999999999','PENDING',true,now()-interval '1 day',20);
  INSERT INTO henvalt.delivery_requests(id,tenant_id)
  SELECT ('99999999-9999-4999-8999-' || lpad(i::text,12,'0'))::uuid,
         '99999999-9999-4999-8999-999999999999'
    FROM generate_series(1,9) AS g(i);
  UPDATE henvalt.delivery_requests SET status='UNKNOWN'
   WHERE tenant_id='99999999-9999-4999-8999-999999999999';
  INSERT INTO henvalt.delivery_attempts(id,tenant_id,delivery_request_id,state,provider_status_code)
  SELECT gen_random_uuid(), '99999999-9999-4999-8999-999999999999',
         ('99999999-9999-4999-8999-' || lpad(i::text,12,'0'))::uuid,
         'FAILED', code
    FROM unnest(ARRAY[400,401,403,404,405,410,413,415,422]) WITH ORDINALITY AS x(code,i);
  IF (SELECT count(*) FROM henvalt.email_usage_reservations
       WHERE tenant_id='99999999-9999-4999-8999-999999999999'
         AND status='RELEASED') <> 9 THEN
    RAISE EXCEPTION 'one or more allowlisted definitive rejections did not release';
  END IF;

  -- Billing-cycle rollover: old measured usage falls out of the new cycle,
  -- but an unresolved provider reservation remains held across the boundary.
  INSERT INTO henvalt.billing_accounts(tenant_id,status,test_mode,activated_at,monthly_email_limit)
  VALUES
    ('aaaaaaaa-1111-4111-8111-111111111111','PENDING',true,now()-interval '1 day',1),
    ('bbbbbbbb-2222-4222-8222-222222222222','PENDING',true,now()-interval '1 day',1);

  INSERT INTO henvalt.email_usage_measurements(tenant_id,delivery_attempt_id,created_at)
  VALUES
    ('aaaaaaaa-1111-4111-8111-111111111111',gen_random_uuid(),now()-interval '60 days'),
    ('bbbbbbbb-2222-4222-8222-222222222222',gen_random_uuid(),now()-interval '60 days');

  INSERT INTO henvalt.delivery_requests(id,tenant_id)
  VALUES
    ('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa1','aaaaaaaa-1111-4111-8111-111111111111'),
    ('bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbb1','bbbbbbbb-2222-4222-8222-222222222222'),
    ('bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbb2','bbbbbbbb-2222-4222-8222-222222222222');

  -- Historical measured usage must not consume the new billing cycle quota.
  UPDATE henvalt.delivery_requests SET status='UNKNOWN'
   WHERE id='aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa1';
  IF (SELECT status FROM henvalt.email_usage_reservations
       WHERE delivery_request_id='aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa1') <> 'RESERVED' THEN
    RAISE EXCEPTION 'prior-cycle measured usage incorrectly blocked new-cycle delivery';
  END IF;

  -- First create a reservation in the old cycle, then simulate the cycle
  -- boundary. Its unresolved status must continue to consume the only slot.
  UPDATE henvalt.delivery_requests SET status='UNKNOWN'
   WHERE id='bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbb1';
  UPDATE henvalt.email_usage_reservations
     SET cycle_start=now()-interval '60 days'
   WHERE delivery_request_id='bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbb1';

  BEGIN
    UPDATE henvalt.delivery_requests SET status='UNKNOWN'
     WHERE id='bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbb2';
    RAISE EXCEPTION 'prior-cycle unresolved reservation did not block new delivery';
  EXCEPTION WHEN insufficient_privilege THEN
    IF SQLERRM NOT LIKE 'HENVALT email usage limit reached%' THEN RAISE; END IF;
  END;
  IF (SELECT status FROM henvalt.delivery_requests
       WHERE id='bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbb2') <> 'PENDING' THEN
    RAISE EXCEPTION 'blocked rollover delivery changed request state';
  END IF;

END
$test$;
SELECT 'email usage reservation acceptance passed' AS result;

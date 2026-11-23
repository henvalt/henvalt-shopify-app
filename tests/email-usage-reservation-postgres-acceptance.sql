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

  INSERT INTO henvalt.delivery_attempts(id,tenant_id,delivery_request_id,state,provider_status_code)
  VALUES(gen_random_uuid(),t,r1,'FAILED',400);
  IF (SELECT status FROM henvalt.email_usage_reservations WHERE delivery_request_id=r1) <> 'RELEASED' THEN
    RAISE EXCEPTION 'definitive provider rejection did not release reservation';
  END IF;

  -- A later acceptance overrides a prior release; the provider's acceptance
  -- evidence is stronger than a previous rejection/timeout classification.
  INSERT INTO henvalt.delivery_attempts(id,tenant_id,delivery_request_id,state,provider_status_code)
  VALUES(gen_random_uuid(),t,r1,'ACCEPTED',202);
  IF (SELECT status FROM henvalt.email_usage_reservations WHERE delivery_request_id=r1) <> 'CONSUMED' THEN
    RAISE EXCEPTION 'late acceptance did not consume released reservation';
  END IF;

  UPDATE henvalt.delivery_requests SET status='UNKNOWN' WHERE id=r2;
  INSERT INTO henvalt.delivery_attempts(id,tenant_id,delivery_request_id,state,provider_status_code)
  VALUES(gen_random_uuid(),t,r2,'UNKNOWN',502);
  IF (SELECT status FROM henvalt.email_usage_reservations WHERE delivery_request_id=r2) <> 'CONSUMED' THEN
    RAISE EXCEPTION 'ambiguous provider result did not consume reservation';
  END IF;
  SELECT count(*) INTO n FROM henvalt.email_usage_measurements WHERE tenant_id=t;
  IF n <> 6 THEN RAISE EXCEPTION 'accepted/ambiguous attempts not measured exactly once: %',n; END IF;

  -- One reserved request at four measured units uses the fifth slot.
  -- Another authorization must fail without changing its PENDING state.
  BEGIN
    UPDATE henvalt.delivery_requests SET status='UNKNOWN' WHERE id=r3;
    RAISE EXCEPTION 'quota cap allowed a sixth email';
  EXCEPTION WHEN insufficient_privilege THEN
    IF SQLERRM NOT LIKE 'HENVALT email usage limit reached%' THEN RAISE; END IF;
  END;
  IF (SELECT status FROM henvalt.delivery_requests WHERE id=r3) <> 'PENDING' THEN
    RAISE EXCEPTION 'denied quota claim changed request state';
  END IF;

  -- Ambiguous 429 is never treated as a definitive rejection.
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

  IF has_table_privilege('anon','henvalt.email_usage_reservations','SELECT')
     OR has_table_privilege('authenticated','henvalt.email_usage_reservations','SELECT')
     OR has_table_privilege('service_role','henvalt.email_usage_reservations','SELECT') THEN
    RAISE EXCEPTION 'email reservation table is exposed to application roles';
  END IF;
END
$test$;
SELECT 'email usage reservation acceptance passed' AS result;

\set ON_ERROR_STOP on
DO $tests$
DECLARE
  p uuid; r uuid; r2 uuid; cmd uuid; got uuid; n integer; v_tenant uuid; v_tags text[];
BEGIN
  -- 01: first generation is generation one.
  p:=gen_random_uuid(); r:=henvalt_test.seed_initial(p);
  IF (SELECT generation_number FROM henvalt_test.delivery_requests WHERE id=r)<>1 THEN RAISE EXCEPTION '01 initial generation'; END IF;

  -- 02: no retry without a prior generation.
  p:=gen_random_uuid(); r:=henvalt_test.seed_initial(p);
  BEGIN PERFORM henvalt_test.create_retry_generation(p,gen_random_uuid()); RAISE EXCEPTION '02 retry without proof accepted';
  EXCEPTION WHEN raise_exception THEN IF SQLERRM='02 retry without proof accepted' THEN RAISE; END IF; END;

  -- 03: trusted pre-provider marker and released reservation permit generation two.
  p:=gen_random_uuid(); r:=henvalt_test.seed_initial(p); PERFORM henvalt_test.mark_pre_provider_failure(r);
  cmd:=gen_random_uuid(); r2:=henvalt_test.create_retry_generation(p,cmd);
  IF (SELECT generation_number FROM henvalt_test.delivery_requests WHERE id=r2)<>2 THEN RAISE EXCEPTION '03 generation two missing'; END IF;

  -- 04: same retry command is idempotent.
  got:=henvalt_test.create_retry_generation(p,cmd);
  IF got<>r2 THEN RAISE EXCEPTION '04 retry command not idempotent'; END IF;

  -- 05: a different retry command cannot create a parallel current generation.
  BEGIN PERFORM henvalt_test.create_retry_generation(p,gen_random_uuid()); RAISE EXCEPTION '05 parallel retry accepted';
  EXCEPTION WHEN raise_exception THEN IF SQLERRM='05 parallel retry accepted' THEN RAISE; END IF; END;

  -- 06: a provider egress marker permanently blocks retry of that generation.
  p:=gen_random_uuid(); r:=henvalt_test.seed_initial(p);
  IF NOT henvalt_test.claim_generation(r) THEN RAISE EXCEPTION '06 claim failed'; END IF;
  IF NOT henvalt_test.start_provider_egress(r) THEN RAISE EXCEPTION '06 egress fence failed'; END IF;
  UPDATE henvalt_test.delivery_requests SET status='FAILED' WHERE id=r;
  INSERT INTO henvalt_test.delivery_attempts(delivery_request_id,attempt_number,state,stage)
  VALUES(r,1,'FAILED','pre_provider');
  UPDATE henvalt_test.reservations SET status='RELEASED' WHERE delivery_request_id=r;
  BEGIN PERFORM henvalt_test.create_retry_generation(p,gen_random_uuid()); RAISE EXCEPTION '06 egress-started request retried';
  EXCEPTION WHEN raise_exception THEN IF SQLERRM='06 egress-started request retried' THEN RAISE; END IF; END;

  -- 07: ambiguous provider outcomes stay consumed and cannot retry.
  p:=gen_random_uuid(); r:=henvalt_test.seed_initial(p); PERFORM henvalt_test.mark_ambiguous(r);
  BEGIN PERFORM henvalt_test.create_retry_generation(p,gen_random_uuid()); RAISE EXCEPTION '07 ambiguous request retried';
  EXCEPTION WHEN raise_exception THEN IF SQLERRM='07 ambiguous request retried' THEN RAISE; END IF; END;

  -- 08: missing reservation is not proof of safe retry.
  p:=gen_random_uuid(); r:=henvalt_test.seed_initial(p); PERFORM henvalt_test.mark_pre_provider_failure(r);
  DELETE FROM henvalt_test.reservations WHERE delivery_request_id=r;
  BEGIN PERFORM henvalt_test.create_retry_generation(p,gen_random_uuid()); RAISE EXCEPTION '08 missing reservation accepted';
  EXCEPTION WHEN raise_exception THEN IF SQLERRM='08 missing reservation accepted' THEN RAISE; END IF; END;

  -- 09: ordinary provider failure without the server-owned marker cannot retry.
  p:=gen_random_uuid(); r:=henvalt_test.seed_initial(p);
  UPDATE henvalt_test.delivery_requests SET status='FAILED' WHERE id=r;
  INSERT INTO henvalt_test.delivery_attempts(delivery_request_id,attempt_number,state,stage,provider_status_code)
  VALUES(r,1,'FAILED','provider_response',400);
  UPDATE henvalt_test.reservations SET status='RELEASED' WHERE delivery_request_id=r;
  BEGIN PERFORM henvalt_test.create_retry_generation(p,gen_random_uuid()); RAISE EXCEPTION '09 provider rejection treated as pre-provider';
  EXCEPTION WHEN raise_exception THEN IF SQLERRM='09 provider rejection treated as pre-provider' THEN RAISE; END IF; END;

  -- 10: late acceptance consumes a released reservation without rewriting FAILED.
  p:=gen_random_uuid(); r:=henvalt_test.seed_initial(p); PERFORM henvalt_test.mark_pre_provider_failure(r);
  IF NOT henvalt_test.settle_late_acceptance('evt-10',r,'msg-10') THEN RAISE EXCEPTION '10 event not accepted'; END IF;
  IF (SELECT status FROM henvalt_test.delivery_requests WHERE id=r)<>'FAILED' THEN RAISE EXCEPTION '10 FAILED history rewritten'; END IF;
  IF (SELECT status FROM henvalt_test.reservations WHERE delivery_request_id=r)<>'CONSUMED' THEN RAISE EXCEPTION '10 reservation not consumed'; END IF;

  -- 11: contradictory late acceptance freezes parent.
  IF (SELECT frozen_at FROM henvalt_test.interventions WHERE id=p) IS NULL THEN RAISE EXCEPTION '11 parent not frozen'; END IF;

  -- 12: duplicate provider event is idempotent.
  IF henvalt_test.settle_late_acceptance('evt-10',r,'msg-10') THEN RAISE EXCEPTION '12 duplicate event reapplied'; END IF;
  IF (SELECT count(*) FROM henvalt_test.delivery_attempts WHERE delivery_request_id=r)<>2 THEN RAISE EXCEPTION '12 duplicate attempt created'; END IF;

  -- 13: frozen parent refuses new retry generation.
  BEGIN PERFORM henvalt_test.create_retry_generation(p,gen_random_uuid()); RAISE EXCEPTION '13 frozen parent retried';
  EXCEPTION WHEN raise_exception THEN IF SQLERRM='13 frozen parent retried' THEN RAISE; END IF; END;

  -- 14: stale generation cannot be claimed after a newer generation exists.
  p:=gen_random_uuid(); r:=henvalt_test.seed_initial(p); PERFORM henvalt_test.mark_pre_provider_failure(r);
  cmd:=gen_random_uuid(); r2:=henvalt_test.create_retry_generation(p,cmd);
  IF henvalt_test.claim_generation(r) THEN RAISE EXCEPTION '14 stale generation claimed'; END IF;

  -- 15: current generation can be claimed.
  IF NOT henvalt_test.claim_generation(r2) THEN RAISE EXCEPTION '15 current generation not claimable'; END IF;

  -- 16: stale generation cannot start provider egress.
  IF henvalt_test.start_provider_egress(r) THEN RAISE EXCEPTION '16 stale generation crossed egress fence'; END IF;

  -- 17: consent is rechecked at claim.
  p:=gen_random_uuid(); r:=henvalt_test.seed_initial(p);
  UPDATE henvalt_test.interventions SET consent_ok=false WHERE id=p;
  IF henvalt_test.claim_generation(r) THEN RAISE EXCEPTION '17 consent bypass'; END IF;

  -- 18: global interlock is rechecked at claim.
  p:=gen_random_uuid(); r:=henvalt_test.seed_initial(p);
  UPDATE henvalt_test.interventions SET interlock_open=false WHERE id=p;
  IF henvalt_test.claim_generation(r) THEN RAISE EXCEPTION '18 interlock bypass'; END IF;

  -- 19: tenant status is rechecked at claim.
  p:=gen_random_uuid(); r:=henvalt_test.seed_initial(p);
  UPDATE henvalt_test.interventions SET tenant_active=false WHERE id=p;
  IF henvalt_test.claim_generation(r) THEN RAISE EXCEPTION '19 tenant status bypass'; END IF;

  -- 20: egress marker is one-shot and cannot be overwritten.
  p:=gen_random_uuid(); r:=henvalt_test.seed_initial(p);
  IF NOT henvalt_test.claim_generation(r) THEN RAISE EXCEPTION '20 claim failed'; END IF;
  IF NOT henvalt_test.start_provider_egress(r) THEN RAISE EXCEPTION '20 first egress marker failed'; END IF;
  IF henvalt_test.start_provider_egress(r) THEN RAISE EXCEPTION '20 egress marker reused'; END IF;

  -- 21: schema constraints preserve both idempotency and generation uniqueness.
  BEGIN
    INSERT INTO henvalt_test.delivery_requests(tenant_id,intervention_id,generation_number,status,idempotency_key)
    SELECT tenant_id,intervention_id,1,'PENDING','duplicate-gen'
      FROM henvalt_test.delivery_requests WHERE id=r;
    RAISE EXCEPTION '21 duplicate generation allowed';
  EXCEPTION WHEN unique_violation THEN NULL; END;

  -- 22: a retry command cannot be rebound to a different generation.
  SELECT count(*) INTO n FROM henvalt_test.retry_commands WHERE delivery_request_id=r2;
  IF n<>1 THEN RAISE EXCEPTION '22 retry command ledger missing'; END IF;

  -- 23: provider acceptance after a later generation freezes both generations.
  p:=gen_random_uuid(); r:=henvalt_test.seed_initial(p); PERFORM henvalt_test.mark_pre_provider_failure(r);
  r2:=henvalt_test.create_retry_generation(p,gen_random_uuid());
  IF NOT henvalt_test.settle_late_acceptance('evt-23',r,'msg-old') THEN RAISE EXCEPTION '23 late event failed'; END IF;
  IF (SELECT frozen_at FROM henvalt_test.interventions WHERE id=p) IS NULL THEN RAISE EXCEPTION '23 contradiction not frozen'; END IF;
  IF henvalt_test.claim_generation(r2) THEN RAISE EXCEPTION '23 newer generation claimed after contradiction'; END IF;
  IF (SELECT status FROM henvalt_test.reservations WHERE delivery_request_id=r)<>'CONSUMED' THEN RAISE EXCEPTION '23 old reservation not consumed'; END IF;

  -- 24: duplicate provider message IDs do not override exact event/request identity.
  p:=gen_random_uuid(); r:=henvalt_test.seed_initial(p); PERFORM henvalt_test.mark_pre_provider_failure(r);
  IF NOT henvalt_test.settle_late_acceptance('evt-24a',r,'shared-message-id') THEN RAISE EXCEPTION '24 first event failed'; END IF;
  IF henvalt_test.settle_late_acceptance('evt-24a',r,'shared-message-id') THEN RAISE EXCEPTION '24 duplicate hash not deduped'; END IF;

  -- 25: consent revoked after claim but before provider egress blocks the fence.
  p:=gen_random_uuid(); r:=henvalt_test.seed_initial(p);
  IF NOT henvalt_test.claim_generation(r) THEN RAISE EXCEPTION '25 claim failed'; END IF;
  UPDATE henvalt_test.interventions SET consent_ok=false WHERE id=p;
  IF henvalt_test.start_provider_egress(r) THEN RAISE EXCEPTION '25 egress ignored revoked consent'; END IF;

  -- 26: global interlock closed after claim but before provider egress blocks the fence.
  p:=gen_random_uuid(); r:=henvalt_test.seed_initial(p);
  IF NOT henvalt_test.claim_generation(r) THEN RAISE EXCEPTION '26 claim failed'; END IF;
  UPDATE henvalt_test.interventions SET interlock_open=false WHERE id=p;
  IF henvalt_test.start_provider_egress(r) THEN RAISE EXCEPTION '26 egress bypassed closed interlock'; END IF;

  -- 27: tenant deactivation after claim but before provider egress blocks the fence.
  p:=gen_random_uuid(); r:=henvalt_test.seed_initial(p);
  IF NOT henvalt_test.claim_generation(r) THEN RAISE EXCEPTION '27 claim failed'; END IF;
  UPDATE henvalt_test.interventions SET tenant_active=false WHERE id=p;
  IF henvalt_test.start_provider_egress(r) THEN RAISE EXCEPTION '27 egress bypassed tenant deactivation'; END IF;

  -- 28: a freeze applied after claim but before provider egress blocks the fence.
  p:=gen_random_uuid(); r:=henvalt_test.seed_initial(p);
  IF NOT henvalt_test.claim_generation(r) THEN RAISE EXCEPTION '28 claim failed'; END IF;
  UPDATE henvalt_test.interventions SET frozen_at=now(),freeze_reason='TEST_FREEZE' WHERE id=p;
  IF henvalt_test.start_provider_egress(r) THEN RAISE EXCEPTION '28 egress bypassed intervention freeze'; END IF;


  -- 29: reusing a provider event identity for another request is a hard conflict.
  p:=gen_random_uuid(); r:=henvalt_test.seed_initial(p); PERFORM henvalt_test.mark_pre_provider_failure(r);
  IF NOT henvalt_test.settle_late_acceptance('evt-29',r,'msg-29') THEN RAISE EXCEPTION '29 first event failed'; END IF;
  p:=gen_random_uuid(); r2:=henvalt_test.seed_initial(p); PERFORM henvalt_test.mark_pre_provider_failure(r2);
  BEGIN
    PERFORM henvalt_test.settle_late_acceptance('evt-29',r2,'msg-29-other');
    RAISE EXCEPTION '29 event identity rebound to another request';
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM='29 event identity rebound to another request' THEN RAISE; END IF;
  END;

  -- 30: a provider message ID already bound to one request cannot be rebound.
  p:=gen_random_uuid(); r:=henvalt_test.seed_initial(p); PERFORM henvalt_test.mark_pre_provider_failure(r);
  IF NOT henvalt_test.settle_late_acceptance('evt-30a',r,'msg-30-shared') THEN RAISE EXCEPTION '30 first event failed'; END IF;
  p:=gen_random_uuid(); r2:=henvalt_test.seed_initial(p); PERFORM henvalt_test.mark_pre_provider_failure(r2);
  BEGIN
    PERFORM henvalt_test.settle_late_acceptance('evt-30b',r2,'msg-30-shared');
    RAISE EXCEPTION '30 provider message ID rebound to another request';
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM='30 provider message ID rebound to another request' THEN RAISE; END IF;
  END;


  -- 31: exact tenant + delivery tags resolve a pre-provider request without a message ID.
  p:=gen_random_uuid(); r:=henvalt_test.seed_initial(p); PERFORM henvalt_test.mark_pre_provider_failure(r);
  SELECT tenant_id INTO v_tenant FROM henvalt_test.interventions WHERE id=p;
  v_tags:=ARRAY['tenant:'||v_tenant::text,'delivery:'||r::text];
  got:=henvalt_test.resolve_delivery_tag(v_tags,'recipient@example.test',NULL);
  IF got<>r THEN RAISE EXCEPTION '31 exact delivery tag did not resolve request'; END IF;
  IF NOT henvalt_test.settle_late_acceptance('evt-31',got,NULL) THEN RAISE EXCEPTION '31 tag-correlated late acceptance failed'; END IF;

  -- 32: missing delivery tag is rejected, never guessed from recipient alone.
  BEGIN
    PERFORM henvalt_test.resolve_delivery_tag(ARRAY['tenant:'||v_tenant::text],'recipient@example.test',NULL);
    RAISE EXCEPTION '32 missing delivery tag was accepted';
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM='32 missing delivery tag was accepted' THEN RAISE; END IF;
  END;

  -- 33: a valid delivery UUID under the wrong tenant cannot resolve.
  p:=gen_random_uuid(); r2:=henvalt_test.seed_initial(p);
  BEGIN
    PERFORM henvalt_test.resolve_delivery_tag(
      ARRAY['tenant:'||v_tenant::text,'delivery:'||r2::text],
      'recipient@example.test',NULL
    );
    RAISE EXCEPTION '33 cross-tenant delivery tag was accepted';
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM='33 cross-tenant delivery tag was accepted' THEN RAISE; END IF;
  END;

  -- 34: provider recipient must match the immutable request recipient.
  BEGIN
    PERFORM henvalt_test.resolve_delivery_tag(v_tags,'other@example.test',NULL);
    RAISE EXCEPTION '34 recipient mismatch was accepted';
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM='34 recipient mismatch was accepted' THEN RAISE; END IF;
  END;

  -- 35: duplicate delivery tags are ambiguous and rejected.
  BEGIN
    PERFORM henvalt_test.resolve_delivery_tag(
      ARRAY['tenant:'||v_tenant::text,'delivery:'||r::text,'delivery:'||r::text],
      'recipient@example.test',NULL
    );
    RAISE EXCEPTION '35 duplicate delivery tags were accepted';
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM='35 duplicate delivery tags were accepted' THEN RAISE; END IF;
  END;

  -- 36: a request already bound to a provider message ID rejects a different ID.
  p:=gen_random_uuid(); r:=henvalt_test.seed_initial(p); PERFORM henvalt_test.mark_pre_provider_failure(r);
  SELECT tenant_id INTO v_tenant FROM henvalt_test.interventions WHERE id=p;
  v_tags:=ARRAY['tenant:'||v_tenant::text,'delivery:'||r::text];
  IF NOT henvalt_test.settle_late_acceptance('evt-36',r,'msg-36') THEN RAISE EXCEPTION '36 first settlement failed'; END IF;
  BEGIN
    PERFORM henvalt_test.resolve_delivery_tag(v_tags,'recipient@example.test','msg-36-other');
    RAISE EXCEPTION '36 provider message ID mismatch was accepted';
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM='36 provider message ID mismatch was accepted' THEN RAISE; END IF;
  END;

  -- 37: a provider message ID bound to another request cannot be reused.
  p:=gen_random_uuid(); r:=henvalt_test.seed_initial(p); PERFORM henvalt_test.mark_pre_provider_failure(r);
  SELECT tenant_id INTO v_tenant FROM henvalt_test.interventions WHERE id=p;
  v_tags:=ARRAY['tenant:'||v_tenant::text,'delivery:'||r::text];
  IF NOT henvalt_test.settle_late_acceptance('evt-37a',r,'msg-37-shared') THEN RAISE EXCEPTION '37 first settlement failed'; END IF;
  p:=gen_random_uuid(); r2:=henvalt_test.seed_initial(p);
  SELECT tenant_id INTO v_tenant FROM henvalt_test.interventions WHERE id=p;
  BEGIN
    PERFORM henvalt_test.resolve_delivery_tag(
      ARRAY['tenant:'||v_tenant::text,'delivery:'||r2::text],
      'recipient@example.test','msg-37-shared'
    );
    RAISE EXCEPTION '37 provider message ID reused across requests';
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM='37 provider message ID reused across requests' THEN RAISE; END IF;
  END;


  -- 38: prior-generation late acceptance freezes a newer generation before its egress fence.
  p:=gen_random_uuid(); r:=henvalt_test.seed_initial(p); PERFORM henvalt_test.mark_pre_provider_failure(r);
  r2:=henvalt_test.create_retry_generation(p,gen_random_uuid());
  IF NOT henvalt_test.settle_late_acceptance('evt-38',r,'msg-38') THEN RAISE EXCEPTION '38 late acceptance failed'; END IF;
  IF henvalt_test.claim_generation(r2) THEN RAISE EXCEPTION '38 newer generation claimed after freeze'; END IF;
  IF henvalt_test.start_provider_egress(r2) THEN RAISE EXCEPTION '38 newer generation crossed egress after freeze'; END IF;

  -- 39: if the newer generation already crossed egress, late evidence freezes future sends;
  -- the in-flight generation remains held and ambiguous rather than being retried.
  p:=gen_random_uuid(); r:=henvalt_test.seed_initial(p); PERFORM henvalt_test.mark_pre_provider_failure(r);
  r2:=henvalt_test.create_retry_generation(p,gen_random_uuid());
  IF NOT henvalt_test.claim_generation(r2) OR NOT henvalt_test.start_provider_egress(r2) THEN
    RAISE EXCEPTION '39 newer generation failed to cross initial egress fence';
  END IF;
  IF NOT henvalt_test.settle_late_acceptance('evt-39',r,'msg-39') THEN RAISE EXCEPTION '39 late acceptance failed'; END IF;
  PERFORM henvalt_test.mark_ambiguous(r2);
  IF (SELECT status FROM henvalt_test.reservations WHERE delivery_request_id=r2)<>'CONSUMED' THEN
    RAISE EXCEPTION '39 in-flight generation quota was not conservatively consumed';
  END IF;
  IF henvalt_test.start_provider_egress(r2) THEN RAISE EXCEPTION '39 frozen in-flight generation re-entered provider egress'; END IF;
  BEGIN
    PERFORM henvalt_test.create_retry_generation(p,gen_random_uuid());
    RAISE EXCEPTION '39 ambiguous in-flight generation was retried';
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM='39 ambiguous in-flight generation was retried' THEN RAISE; END IF;
  END;

END
$tests$;
SELECT 'delivery generation PostgreSQL model acceptance passed (39 cases)' AS result;

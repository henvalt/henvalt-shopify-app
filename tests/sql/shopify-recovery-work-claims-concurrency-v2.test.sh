#!/usr/bin/env bash
set -euo pipefail
export PGPASSWORD="${PGPASSWORD:-postgres}"
psql_cmd=(psql -h 127.0.0.1 -U postgres -d postgres -v ON_ERROR_STOP=1)

set +e
"${psql_cmd[@]}" -Atc "SELECT set_config('request.jwt.claim.role','service_role',false); SELECT henvalt.claim_shopify_recovery_work_v2('claim-race-worker-a',100,120)" >/tmp/henvalt-claim-race-a.log 2>&1 &
pid_a=$!
"${psql_cmd[@]}" -Atc "SELECT set_config('request.jwt.claim.role','service_role',false); SELECT henvalt.claim_shopify_recovery_work_v2('claim-race-worker-b',100,120)" >/tmp/henvalt-claim-race-b.log 2>&1 &
pid_b=$!
wait "$pid_a"; status_a=$?
wait "$pid_b"; status_b=$?
set -e
if [[ "$status_a" -ne 0 || "$status_b" -ne 0 ]]; then
 cat /tmp/henvalt-claim-race-a.log /tmp/henvalt-claim-race-b.log
 echo "Concurrent recovery claim failed." >&2
 exit 1
fi

claim_rows=$("${psql_cmd[@]}" -Atc "
 SELECT count(*)||':'||coalesce(max(c.attempt_count),0)||':'||count(DISTINCT c.worker_id)
 FROM henvalt.shopify_recovery_work_claims_v2 c
 JOIN henvalt.test_recovery_work_claim_fixture_v2 f
  ON c.work_type='PIXEL_OPPORTUNITY' AND c.work_id=f.opportunity_id
")
if [[ "$claim_rows" != "1:1:1" ]]; then
 cat /tmp/henvalt-claim-race-a.log /tmp/henvalt-claim-race-b.log
 echo "Expected exactly one owner and one claim attempt for the raced opportunity; got $claim_rows." >&2
 exit 1
fi

# Exercise the fifth permitted attempt and prove DEFERRED becomes operator-review work.
"${psql_cmd[@]}" <<'SQL'
DO $retry$
DECLARE
 v_fixture henvalt.test_recovery_work_claim_fixture_v2%ROWTYPE;
 v_claim jsonb;
 v_finish jsonb;
 v_lease uuid;
 v_crashed_id uuid:=extensions.gen_random_uuid();
BEGIN
 SELECT * INTO STRICT v_fixture FROM henvalt.test_recovery_work_claim_fixture_v2 LIMIT 1;
 UPDATE henvalt.shopify_recovery_work_claims_v2
 SET attempt_count=4,worker_id='retry-test-worker',
     lease_expires_at=now()-interval '1 second',
     next_attempt_at=now()-interval '1 second'
 WHERE work_type='PIXEL_OPPORTUNITY' AND work_id=v_fixture.opportunity_id;

 PERFORM pg_catalog.set_config('request.jwt.claim.role','service_role',true);
 v_claim:=henvalt.claim_shopify_recovery_work_v2('retry-test-worker',100,120);
 SELECT (item->>'lease_id')::uuid INTO v_lease
 FROM jsonb_array_elements(v_claim->'items') item
 WHERE item->>'work_id'=v_fixture.opportunity_id::text
   AND item->>'work_type'='PIXEL_OPPORTUNITY';
 IF v_lease IS NULL THEN
  RAISE EXCEPTION 'Final permitted retry was not claimable: %',v_claim;
 END IF;
 v_finish:=henvalt.finish_shopify_recovery_work_claim_v2(
  v_lease,'retry-test-worker','DEFERRED',interval '1 hour'
 );
 IF v_finish->>'finished'<>'true' OR v_finish->>'exhausted'<>'true'
    OR v_finish->>'reason_code'<>'retry_limit_reached' THEN
  RAISE EXCEPTION 'Fifth deferred attempt did not enter exhausted review: %',v_finish;
 END IF;

 -- A worker crash on the final attempt is exhausted by the next claim tick
 -- after its lease expires; it must never be reclaimed.
 INSERT INTO henvalt.shopify_recovery_work_claims_v2(
  id,work_type,work_id,tenant_id,shopify_connection_id,worker_id,
  lease_expires_at,next_attempt_at,attempt_count,max_attempt_count
 ) VALUES(v_crashed_id,'PIXEL_OPPORTUNITY',extensions.gen_random_uuid(),
  v_fixture.tenant_id,v_fixture.shopify_connection_id,'crashed-worker',
  now()-interval '1 second',now()-interval '1 second',5,5);
 v_claim:=henvalt.claim_shopify_recovery_work_v2('retry-sweeper',100,120);
 IF coalesce((v_claim->>'exhausted_marked')::integer,0)<1 THEN
  RAISE EXCEPTION 'Expired final lease was not swept into exhausted review: %',v_claim;
 END IF;
 IF (SELECT count(*) FROM henvalt.shopify_recovery_exhausted_work_v2
     WHERE id IN (v_lease,v_crashed_id))<>2 THEN
  RAISE EXCEPTION 'Operator-review view did not retain both exhausted work items';
 END IF;
END;
$retry$;
SQL

"${psql_cmd[@]}" <<'SQL'
DELETE FROM henvalt.shopify_recovery_work_claims_v2 c
WHERE c.tenant_id=(SELECT tenant_id FROM henvalt.test_recovery_work_claim_fixture_v2 LIMIT 1)
  AND c.shopify_connection_id=(SELECT shopify_connection_id FROM henvalt.test_recovery_work_claim_fixture_v2 LIMIT 1)
  AND c.worker_id IN ('exhausted','retry-test-worker','crashed-worker');
DELETE FROM henvalt.shopify_recovery_opportunity_v2 o
USING henvalt.test_recovery_work_claim_fixture_v2 f
WHERE o.id=f.opportunity_id;
DELETE FROM henvalt.shopify_pixel_recovery_candidate_v2 c
USING henvalt.test_recovery_work_claim_fixture_v2 f
WHERE c.id=f.pixel_candidate_id;
DELETE FROM henvalt.shopify_session_identity_v2 s
USING henvalt.test_recovery_work_claim_fixture_v2 f
WHERE s.id=f.session_identity_id;
DELETE FROM henvalt.shopify_pixel_event_inbox_v2 e
USING henvalt.test_recovery_work_claim_fixture_v2 f
WHERE e.id=f.inbox_event_id;
DROP TABLE henvalt.test_recovery_work_claim_fixture_v2;
SQL
echo "shopify_recovery_work_claim_concurrency_v2_passed"

#!/usr/bin/env bash
set -euo pipefail
export PGPASSWORD="${PGPASSWORD:-postgres}"
psql_cmd=(psql -h 127.0.0.1 -U postgres -d postgres -v ON_ERROR_STOP=1)

set +e
"${psql_cmd[@]}" -Atc "SELECT henvalt.claim_shopify_recovery_work_v2('claim-race-worker-a',100,120)" >/tmp/henvalt-claim-race-a.log 2>&1 &
pid_a=$!
"${psql_cmd[@]}" -Atc "SELECT henvalt.claim_shopify_recovery_work_v2('claim-race-worker-b',100,120)" >/tmp/henvalt-claim-race-b.log 2>&1 &
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

"${psql_cmd[@]}" <<'SQL'
DELETE FROM henvalt.shopify_recovery_work_claims_v2 c
USING henvalt.test_recovery_work_claim_fixture_v2 f
WHERE c.work_type='PIXEL_OPPORTUNITY' AND c.work_id=f.opportunity_id;
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

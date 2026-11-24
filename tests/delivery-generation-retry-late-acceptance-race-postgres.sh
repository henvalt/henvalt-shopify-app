#!/usr/bin/env bash
set -euo pipefail
: "${PGHOST:=127.0.0.1}"; : "${PGPORT:=5432}"; : "${PGUSER:=postgres}"; : "${PGDATABASE:=delivery_generation_prodshape}"; : "${PGPASSWORD:=postgres}"
export PGHOST PGPORT PGUSER PGDATABASE PGPASSWORD

seed_case() {
  local tenant="$1" parent="$2" request="$3" job="$4" recipient="$5" idem="$6" worker="$7"
  psql -v ON_ERROR_STOP=1 <<SQL
SET request.jwt.claim.role='service_role';
INSERT INTO henvalt.recovery_interventions(id,tenant_id,opportunity_id,channel,status)
VALUES('$parent','$tenant',gen_random_uuid(),'EMAIL','FAILED');
INSERT INTO henvalt.delivery_requests(
  id,tenant_id,intervention_id,channel,delivery_mode,recipient_reference,
  status,provider,idempotency_key,correlation_id,generation_number
) VALUES(
  '$request','$tenant','$parent','EMAIL','HENVALT_MANAGED',
  '$recipient','FAILED','mailersend','$idem',gen_random_uuid(),1
);
INSERT INTO henvalt.delivery_attempts(
  tenant_id,delivery_request_id,attempt_number,state,provider_status_code,provider_response
) VALUES(
  '$tenant','$request',1,'FAILED',409,
  '{"henvalt_delivery_stage":"pre_provider","error":"synthetic_pre_provider_failure"}'::jsonb
) RETURNING id AS attempt_id \gset
INSERT INTO henvalt.email_usage_reservations(
  tenant_id,delivery_request_id,status,status_reason,last_attempt_id
) VALUES('$tenant','$request','RELEASED','PRE_PROVIDER_FAILURE',:'attempt_id');
INSERT INTO henvalt.email_usage_reservation_events(
  reservation_id,tenant_id,delivery_request_id,event_type,previous_status,
  new_status,delivery_attempt_id,reason
)
SELECT id,'$tenant','$request','RELEASED','RESERVED','RELEASED',
       :'attempt_id','PRE_PROVIDER_FAILURE'
FROM henvalt.email_usage_reservations WHERE delivery_request_id='$request';
INSERT INTO henvalt.background_jobs(
  id,tenant_id,job_type,payload,status,locked_by
) VALUES(
  '$job','$tenant','execute_intervention',
  jsonb_build_object('tenant_id','$tenant'::uuid,'intervention_id','$parent'::uuid),
  'CLAIMED','$worker'
);
SQL
}

wait_for_barrier() {
  local app="$1" pid="$2" log="$3"
  local ready=0
  for _ in $(seq 1 120); do
    local active
    active="$(psql -Atqc "SELECT count(*) FROM pg_stat_activity WHERE application_name='$app' AND query LIKE '%pg_sleep%';")"
    if [[ "$active" == "1" ]]; then ready=1; break; fi
    sleep 0.05
  done
  if [[ "$ready" != "1" ]]; then
    cat "$log"
    kill "$pid" 2>/dev/null || true
    echo "race session missed parent-lock barrier: $app" >&2
    exit 1
  fi
}

# Case A: retry creation wins the intervention lock. A later exact-tag provider
# acceptance must freeze the parent and make the queued generation un-loadable.
tenant_a='e1000000-0000-4000-8000-000000000001'
parent_a='e2000000-0000-4000-8000-000000000001'
request_a='e3000000-0000-4000-8000-000000000001'
job_a='e4000000-0000-4000-8000-000000000001'
worker_a='retry-first-worker'
seed_case "$tenant_a" "$parent_a" "$request_a" "$job_a" "retry-first@example.test" "retry-first-g1" "$worker_a"

first_log="$(mktemp)"
PGAPPNAME=retry-first-wins psql -v ON_ERROR_STOP=1 >"$first_log" 2>&1 <<SQL &
SET request.jwt.claim.role='service_role';
BEGIN;
SELECT id FROM henvalt.recovery_interventions WHERE id='$parent_a' FOR UPDATE;
SELECT pg_sleep(1.2);
SELECT henvalt.enqueue_delivery_retry_generation_job(
  '$tenant_a','$parent_a','$job_a','$worker_a'
);
COMMIT;
SQL
first_pid=$!
wait_for_barrier "retry-first-wins" "$first_pid" "$first_log"

PGAPPNAME=late-event-after-retry psql -v ON_ERROR_STOP=1 <<SQL
SET request.jwt.claim.role='service_role';
SELECT henvalt.process_mailersend_webhook_event(
  jsonb_build_object('type','activity.delivered','data',jsonb_build_object(
    'message_id','retry-first-late-message',
    'email','retry-first@example.test',
    'tags',jsonb_build_array('tenant:$tenant_a','delivery:$request_a')
  )),
  'retry-first-late-event'
);
SQL
wait "$first_pid"

retry_job_a="$(psql -Atqc "SELECT job_id FROM henvalt.delivery_retry_jobs WHERE intervention_id='$parent_a';")"
[[ -n "$retry_job_a" ]] || { echo "retry-first race did not enqueue generation job" >&2; exit 1; }
psql -v ON_ERROR_STOP=1 <<SQL
SET request.jwt.claim.role='service_role';
UPDATE henvalt.background_jobs
   SET status='CLAIMED',locked_by='delivery-worker-after-late',locked_at=clock_timestamp()
 WHERE id='$retry_job_a';
SQL
loadable_a="$(psql -Atqc "SELECT count(*) FROM henvalt.load_delivery_retry_envelope(
  '$retry_job_a','delivery-worker-after-late','$tenant_a','$parent_a',
  (SELECT delivery_request_id FROM henvalt.delivery_retry_jobs WHERE job_id='$retry_job_a'),2
);")"
[[ "$loadable_a" == "0" ]] || { echo "queued generation remained loadable after late acceptance froze parent" >&2; exit 1; }
state_a="$(psql -AtF '|' -c "SELECT
  (delivery_frozen_at IS NOT NULL),
  delivery_freeze_reason,
  (SELECT status::text FROM henvalt.delivery_requests WHERE id='$request_a'),
  (SELECT status FROM henvalt.email_usage_reservations WHERE delivery_request_id='$request_a'),
  (SELECT count(*) FROM henvalt.delivery_attempts WHERE delivery_request_id='$request_a'),
  (SELECT count(*) FROM henvalt.delivery_generation_incidents WHERE intervention_id='$parent_a')
FROM henvalt.recovery_interventions WHERE id='$parent_a';")"
[[ "$state_a" == "t|LATE_PROVIDER_ACCEPTANCE|FAILED|CONSUMED|1|1" ]] || {
  echo "retry-first late-acceptance settlement mismatch: $state_a" >&2; exit 1;
}

# Case B: late acceptance wins the intervention lock. The waiting retry worker
# must complete as blocked and must not create generation 2 or a retry job.
tenant_b='e1000000-0000-4000-8000-000000000002'
parent_b='e2000000-0000-4000-8000-000000000002'
request_b='e3000000-0000-4000-8000-000000000002'
job_b='e4000000-0000-4000-8000-000000000002'
worker_b='retry-after-late-worker'
seed_case "$tenant_b" "$parent_b" "$request_b" "$job_b" "late-first@example.test" "late-first-g1" "$worker_b"

late_log="$(mktemp)"
PGAPPNAME=late-first-wins psql -v ON_ERROR_STOP=1 >"$late_log" 2>&1 <<SQL &
SET request.jwt.claim.role='service_role';
BEGIN;
SELECT id FROM henvalt.recovery_interventions WHERE id='$parent_b' FOR UPDATE;
SELECT pg_sleep(1.2);
SELECT henvalt.process_mailersend_webhook_event(
  jsonb_build_object('type','activity.sent','data',jsonb_build_object(
    'message_id','late-first-message',
    'email','late-first@example.test',
    'tags',jsonb_build_array('tenant:$tenant_b','delivery:$request_b')
  )),
  'late-first-event'
);
COMMIT;
SQL
late_pid=$!
wait_for_barrier "late-first-wins" "$late_pid" "$late_log"

PGAPPNAME=retry-after-late psql -v ON_ERROR_STOP=1 <<SQL
SET request.jwt.claim.role='service_role';
SELECT henvalt.enqueue_delivery_retry_generation_job(
  '$tenant_b','$parent_b','$job_b','$worker_b'
);
SQL
wait "$late_pid"

state_b="$(psql -AtF '|' -c "SELECT
  (delivery_frozen_at IS NOT NULL),
  delivery_freeze_reason,
  (SELECT status::text FROM henvalt.delivery_requests WHERE id='$request_b'),
  (SELECT status FROM henvalt.email_usage_reservations WHERE delivery_request_id='$request_b'),
  (SELECT count(*) FROM henvalt.delivery_requests WHERE intervention_id='$parent_b'),
  (SELECT count(*) FROM henvalt.delivery_retry_jobs WHERE intervention_id='$parent_b'),
  (SELECT status::text FROM henvalt.background_jobs WHERE id='$job_b'),
  (SELECT count(*) FROM henvalt.delivery_generation_incidents WHERE intervention_id='$parent_b')
FROM henvalt.recovery_interventions WHERE id='$parent_b';")"
[[ "$state_b" == "t|LATE_PROVIDER_ACCEPTANCE|FAILED|CONSUMED|1|0|SUCCEEDED|1" ]] || {
  echo "late-first retry-block settlement mismatch: $state_b" >&2; exit 1;
}

echo "production-shaped retry-generation vs late-acceptance lock races passed in both orders"

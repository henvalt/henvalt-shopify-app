#!/usr/bin/env bash
set -euo pipefail

: "${PGPASSWORD:?PGPASSWORD must be set for the disposable PostgreSQL service}"
PGHOST="${PGHOST:-127.0.0.1}"
PGPORT="${PGPORT:-5432}"
PGUSER="${PGUSER:-postgres}"
PGDATABASE="${PGDATABASE:-postgres}"
export PGHOST PGPORT PGUSER PGDATABASE

psqlx() { psql -X -v ON_ERROR_STOP=1 "$@"; }

tenant_id="abababab-abab-4bab-8bab-abababababab"
webhook_id="abababab-abab-4bab-8bab-abababababac"
job_id="abababab-abab-4bab-8bab-abababababad"

psqlx <<SQL
INSERT INTO henvalt.tenants(id,status)
VALUES ('$tenant_id','ACTIVE')
ON CONFLICT (id) DO NOTHING;

UPDATE henvalt.background_jobs
   SET status='SUCCEEDED',locked_by=NULL,locked_at=NULL,lease_id=NULL,
       lease_expires_at=NULL,completed_at=clock_timestamp(),next_run_at=NULL
 WHERE job_type='process_shopify_webhook'
   AND id <> '$job_id'
   AND status <> 'SUCCEEDED';

INSERT INTO henvalt.webhook_events(
  id,tenant_id,source,source_event_id,topic,idempotency_key,
  payload,metadata,processing_status
) VALUES (
  '$webhook_id','$tenant_id','shopify','lease-concurrency-event',
  'orders/create','lease-concurrency-event',
  '{"id":"lease-concurrency-test","test":true}'::jsonb,
  '{"ingress_hmac_verified":true}'::jsonb,'PROCESSING'
)
ON CONFLICT (id) DO UPDATE SET
  tenant_id=EXCLUDED.tenant_id,processing_status='PROCESSING';

INSERT INTO henvalt.background_jobs(
  id,tenant_id,job_type,payload,status,attempts,max_attempts,idempotency_key
) VALUES (
  '$job_id','$tenant_id','process_shopify_webhook',
  jsonb_build_object('webhook_id','$webhook_id'::uuid),
  'QUEUED',0,5,'lease-concurrency-job'
)
ON CONFLICT (id) DO UPDATE SET
  tenant_id=EXCLUDED.tenant_id,payload=EXCLUDED.payload,
  status='QUEUED',attempts=0,max_attempts=5,locked_by=NULL,
  locked_at=NULL,lease_id=NULL,lease_expires_at=NULL,
  completed_at=NULL,next_run_at=NULL,last_error=NULL;
SQL

lease_id="$(psqlx -Atq -c "SELECT lease_id FROM henvalt.claim_shopify_replay_job('race-owner',60) WHERE id='$job_id'")"
if [[ -z "$lease_id" ]]; then
  echo "CONCURRENCY_FIXTURE_CLAIM_FAILED" >&2
  exit 1
fi

# Make the committed lease expire shortly after the owner starts. The write guard
# then locks the row and renews it inside the still-open business-write transaction.
psqlx -c "UPDATE henvalt.background_jobs SET lease_expires_at=clock_timestamp()+interval '5 seconds' WHERE id='$job_id' AND lease_id='$lease_id'"

tmpdir="$(mktemp -d)"
owner_pid=""
cleanup() {
  if [[ -n "$owner_pid" ]]; then
    kill "$owner_pid" 2>/dev/null || true
    wait "$owner_pid" 2>/dev/null || true
  fi
  rm -rf "$tmpdir"
}
trap cleanup EXIT

psqlx -c "BEGIN; SELECT henvalt.assert_shopify_replay_lease_for_write('$job_id','race-owner','$lease_id'); SELECT pg_sleep(12); COMMIT;" >"$tmpdir/owner.log" 2>&1 &
owner_pid=$!

# Wait until the original committed lease has expired while the owner transaction
# is still holding the row lock after its in-transaction heartbeat.
sleep 7
contender="$(psqlx -Atq -c "SELECT id::text || ':' || lease_id::text FROM henvalt.claim_shopify_replay_job('race-contender',60) WHERE id='$job_id'")"
if [[ -n "$contender" ]]; then
  echo "CONCURRENT_RECLAIM_BYPASSED_ACTIVE_WRITE_LOCK: $contender" >&2
  exit 1
fi

wait "$owner_pid"
owner_pid=""

still_owner="$(psqlx -Atq -c "SELECT count(*) FROM henvalt.background_jobs WHERE id='$job_id' AND locked_by='race-owner' AND lease_id='$lease_id' AND lease_expires_at>clock_timestamp()")"
if [[ "$still_owner" != "1" ]]; then
  cat "$tmpdir/owner.log" >&2
  echo "OWNER_HEARTBEAT_NOT_COMMITTED" >&2
  exit 1
fi

# Once the owner transaction commits, an actually expired lease may be reclaimed.
psqlx -c "UPDATE henvalt.background_jobs SET lease_expires_at=clock_timestamp()-interval '1 second' WHERE id='$job_id' AND lease_id='$lease_id'"
new_lease="$(psqlx -Atq -c "SELECT lease_id FROM henvalt.claim_shopify_replay_job('race-after-commit',60) WHERE id='$job_id'")"
if [[ -z "$new_lease" || "$new_lease" == "$lease_id" ]]; then
  echo "RECLAIM_AFTER_OWNER_COMMIT_FAILED" >&2
  exit 1
fi

psqlx -c "UPDATE henvalt.background_jobs SET status='SUCCEEDED',locked_by=NULL,locked_at=NULL,lease_id=NULL,lease_expires_at=NULL,completed_at=clock_timestamp() WHERE id='$job_id' AND lease_id='$new_lease'"
echo "SHOPIFY_REPLAY_LEASE_CONCURRENCY_ACCEPTANCE_PASSED"

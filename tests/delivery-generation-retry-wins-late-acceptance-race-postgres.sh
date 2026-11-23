#!/usr/bin/env bash
set -euo pipefail
: "${PGHOST:=127.0.0.1}"; : "${PGPORT:=5432}"; : "${PGUSER:=postgres}"; : "${PGDATABASE:=postgres}"; : "${PGPASSWORD:=postgres}"
export PGHOST PGPORT PGUSER PGDATABASE PGPASSWORD
parent='abababab-abab-4bab-8bab-abababababab'
event='retry-wins-late-acceptance-002'
psql -v ON_ERROR_STOP=1 <<SQL
SELECT henvalt_test.seed_initial('$parent') AS request_id \gset
SELECT henvalt_test.mark_pre_provider_failure(:'request_id');
SQL
first_log="$(mktemp)"; second_log="$(mktemp)"
PGAPPNAME=retry-first psql -v ON_ERROR_STOP=1 >"$first_log" 2>&1 <<SQL &
BEGIN;
SELECT id FROM henvalt_test.interventions WHERE id='$parent' FOR UPDATE;
SELECT pg_sleep(1.2);
SELECT henvalt_test.create_retry_generation('$parent','abababab-1111-4111-8111-abababababab');
COMMIT;
SQL
first_pid=$!
ready=0
for _ in $(seq 1 100); do
  active=$(psql -Atqc "SELECT count(*) FROM pg_stat_activity WHERE application_name='retry-first' AND query LIKE '%pg_sleep%';")
  if [[ "$active" == "1" ]]; then ready=1; break; fi
  sleep 0.03
done
if [[ "$ready" != "1" ]]; then cat "$first_log"; kill "$first_pid" 2>/dev/null || true; echo "retry session missed barrier" >&2; exit 1; fi
PGAPPNAME=late-event-second psql -v ON_ERROR_STOP=1 >"$second_log" 2>&1 <<SQL
SELECT henvalt_test.settle_late_acceptance('$event',
  (SELECT id FROM henvalt_test.delivery_requests WHERE intervention_id='$parent' AND generation_number=1),
  'msg-old');
SQL
wait "$first_pid"
frozen=$(psql -Atqc "SELECT frozen_at IS NOT NULL FROM henvalt_test.interventions WHERE id='$parent';")
[[ "$frozen" == "t" ]] || { echo "late acceptance did not freeze parent after retry won" >&2; exit 1; }
current=$(psql -Atqc "SELECT id FROM henvalt_test.delivery_requests WHERE intervention_id='$parent' AND generation_number=2;")
if psql -v ON_ERROR_STOP=1 -Atqc "SELECT henvalt_test.claim_generation('$current');" | grep -qx t; then
  echo "new generation was claimable after contradictory late acceptance" >&2
  exit 1
fi
echo "retry-generation vs late-acceptance race passed; parent frozen before next claim"

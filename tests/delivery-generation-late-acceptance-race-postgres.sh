#!/usr/bin/env bash
set -euo pipefail
: "\${PGHOST:=127.0.0.1}"; : "\${PGPORT:=5432}"; : "\${PGUSER:=postgres}"; : "\${PGDATABASE:=postgres}"; : "\${PGPASSWORD:=postgres}"
export PGHOST PGPORT PGUSER PGDATABASE PGPASSWORD
parent='ffffffff-ffff-4fff-8fff-ffffffffffff'
event='late-acceptance-vs-retry-001'
psql -v ON_ERROR_STOP=1 <<SQL
SELECT henvalt_test.seed_initial('$parent') AS request_id \\gset
SELECT henvalt_test.mark_pre_provider_failure(:'request_id');
SQL
first_log="$(mktemp)"; second_log="$(mktemp)"
PGAPPNAME=late-acceptance-first psql -v ON_ERROR_STOP=1 >"$first_log" 2>&1 <<SQL &
BEGIN;
SELECT id FROM henvalt_test.interventions WHERE id='$parent' FOR UPDATE;
SELECT pg_sleep(1.2);
SELECT henvalt_test.settle_late_acceptance('$event', (SELECT id FROM henvalt_test.delivery_requests WHERE intervention_id='$parent' AND generation_number=1), 'msg-late');
COMMIT;
SQL
first_pid=$!
ready=0
for _ in $(seq 1 100); do
  active=$(psql -Atqc "SELECT count(*) FROM pg_stat_activity WHERE application_name='late-acceptance-first' AND query LIKE '%pg_sleep%';")
  if [[ "$active" == "1" ]]; then ready=1; break; fi
  sleep 0.03
done
if [[ "$ready" != "1" ]]; then cat "$first_log"; kill "$first_pid" 2>/dev/null || true; echo "late-acceptance session missed barrier" >&2; exit 1; fi
if PGAPPNAME=retry-second psql -v ON_ERROR_STOP=1 >"$second_log" 2>&1 <<SQL
SELECT henvalt_test.create_retry_generation('$parent','99999999-9999-4999-8999-999999999999');
SQL
then
  echo "retry unexpectedly succeeded after late acceptance won parent lock" >&2
  cat "$second_log"
  kill "$first_pid" 2>/dev/null || true
  exit 1
fi
wait "$first_pid"
frozen=$(psql -Atqc "SELECT frozen_at IS NOT NULL FROM henvalt_test.interventions WHERE id='$parent';")
[[ "$frozen" == "t" ]] || { echo "late acceptance did not freeze intervention" >&2; exit 1; }
count=$(psql -Atqc "SELECT count(*) FROM henvalt_test.delivery_requests WHERE intervention_id='$parent';")
[[ "$count" == "1" ]] || { echo "retry generation appeared despite late acceptance" >&2; exit 1; }
echo "late-acceptance vs retry-generation race passed"

#!/usr/bin/env bash
set -euo pipefail
: "\${PGHOST:=127.0.0.1}"; : "\${PGPORT:=5432}"; : "\${PGUSER:=postgres}"; : "\${PGDATABASE:=postgres}"; : "\${PGPASSWORD:=postgres}"
export PGHOST PGPORT PGUSER PGDATABASE PGPASSWORD
parent='cdcdcdcd-cdcd-4dcd-8dcd-cdcdcdcdcdcd'
event='late-acceptance-before-egress-003'
psql -v ON_ERROR_STOP=1 <<SQL
SELECT henvalt_test.seed_initial('$parent') AS old_request \\gset
SELECT henvalt_test.mark_pre_provider_failure(:'old_request');
SELECT henvalt_test.create_retry_generation('$parent','cdcdcdcd-1111-4111-8111-cdcdcdcdcdcd') AS new_request \\gset
SQL
old_request=$(psql -Atqc "SELECT id FROM henvalt_test.delivery_requests WHERE intervention_id='$parent' AND generation_number=1;")
new_request=$(psql -Atqc "SELECT id FROM henvalt_test.delivery_requests WHERE intervention_id='$parent' AND generation_number=2;")
psql -v ON_ERROR_STOP=1 -Atqc "SELECT henvalt_test.claim_generation('$new_request');" | grep -qx t
first_log="$(mktemp)"; second_log="$(mktemp)"
PGAPPNAME=late-before-egress psql -v ON_ERROR_STOP=1 >"$first_log" 2>&1 <<SQL &
BEGIN;
SELECT id FROM henvalt_test.interventions WHERE id='$parent' FOR UPDATE;
SELECT pg_sleep(1.2);
SELECT henvalt_test.settle_late_acceptance('$event','$old_request','msg-old');
COMMIT;
SQL
first_pid=$!
ready=0
for _ in $(seq 1 100); do
  active=$(psql -Atqc "SELECT count(*) FROM pg_stat_activity WHERE application_name='late-before-egress' AND query LIKE '%pg_sleep%';")
  if [[ "$active" == "1" ]]; then ready=1; break; fi
  sleep 0.03
done
if [[ "$ready" != "1" ]]; then cat "$first_log"; kill "$first_pid" 2>/dev/null || true; echo "late event session missed barrier" >&2; exit 1; fi
PGAPPNAME=egress-after-late psql -v ON_ERROR_STOP=1 >"$second_log" 2>&1 <<SQL
SELECT henvalt_test.start_provider_egress('$new_request');
SQL
wait "$first_pid"
grep -qx f "$second_log" || { echo "egress was not denied after late acceptance won" >&2; cat "$second_log"; exit 1; }
marker=$(psql -Atqc "SELECT provider_egress_started_at IS NOT NULL FROM henvalt_test.delivery_requests WHERE id='$new_request';")
[[ "$marker" == "f" ]] || { echo "egress marker was set after late acceptance" >&2; exit 1; }
echo "late acceptance before provider-egress race passed"

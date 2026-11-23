#!/usr/bin/env bash
set -euo pipefail
: "\${PGHOST:=127.0.0.1}"; : "\${PGPORT:=5432}"; : "\${PGUSER:=postgres}"; : "\${PGDATABASE:=postgres}"; : "\${PGPASSWORD:=postgres}"
export PGHOST PGPORT PGUSER PGDATABASE PGPASSWORD
parent='dededede-dede-4ded-8ded-dededededede'
event='egress-before-late-acceptance-004'
psql -v ON_ERROR_STOP=1 <<SQL
SELECT henvalt_test.seed_initial('$parent') AS old_request \\gset
SELECT henvalt_test.mark_pre_provider_failure(:'old_request');
SELECT henvalt_test.create_retry_generation('$parent','dededede-1111-4111-8111-dededededede');
SQL
old_request=$(psql -Atqc "SELECT id FROM henvalt_test.delivery_requests WHERE intervention_id='$parent' AND generation_number=1;")
new_request=$(psql -Atqc "SELECT id FROM henvalt_test.delivery_requests WHERE intervention_id='$parent' AND generation_number=2;")
psql -v ON_ERROR_STOP=1 -Atqc "SELECT henvalt_test.claim_generation('$new_request');" | grep -qx t
first_log="$(mktemp)"; second_log="$(mktemp)"
PGAPPNAME=egress-before-late psql -v ON_ERROR_STOP=1 >"$first_log" 2>&1 <<SQL &
BEGIN;
SELECT id FROM henvalt_test.interventions WHERE id='$parent' FOR UPDATE;
SELECT pg_sleep(1.2);
SELECT henvalt_test.start_provider_egress('$new_request');
COMMIT;
SQL
first_pid=$!
ready=0
for _ in $(seq 1 100); do
  active=$(psql -Atqc "SELECT count(*) FROM pg_stat_activity WHERE application_name='egress-before-late' AND query LIKE '%pg_sleep%';")
  if [[ "$active" == "1" ]]; then ready=1; break; fi
  sleep 0.03
done
if [[ "$ready" != "1" ]]; then cat "$first_log"; kill "$first_pid" 2>/dev/null || true; echo "egress session missed barrier" >&2; exit 1; fi
PGAPPNAME=late-after-egress psql -v ON_ERROR_STOP=1 >"$second_log" 2>&1 <<SQL
SELECT henvalt_test.settle_late_acceptance('$event','$old_request','msg-old');
SQL
wait "$first_pid"
grep -qx t "$first_log" || { echo "egress did not win parent lock" >&2; cat "$first_log"; exit 1; }
frozen=$(psql -Atqc "SELECT frozen_at IS NOT NULL FROM henvalt_test.interventions WHERE id='$parent';")
marker=$(psql -Atqc "SELECT provider_egress_started_at IS NOT NULL FROM henvalt_test.delivery_requests WHERE id='$new_request';")
[[ "$frozen" == "t" && "$marker" == "t" ]] || { echo "expected egress-started generation and frozen parent" >&2; exit 1; }
psql -v ON_ERROR_STOP=1 -Atqc "SELECT henvalt_test.mark_ambiguous('$new_request');" >/dev/null
reserved=$(psql -Atqc "SELECT status FROM henvalt_test.reservations WHERE delivery_request_id='$new_request';")
[[ "$reserved" == "CONSUMED" ]] || { echo "in-flight generation was not conservatively consumed" >&2; exit 1; }
if psql -v ON_ERROR_STOP=1 -Atqc "SELECT henvalt_test.start_provider_egress('$new_request');" | grep -qx t; then
  echo "frozen generation re-entered provider egress" >&2
  exit 1
fi
echo "provider egress before late acceptance race passed; in-flight quota held as consumed"

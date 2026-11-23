#!/usr/bin/env bash
set -euo pipefail
: "\${PGHOST:=127.0.0.1}"; : "\${PGPORT:=5432}"; : "\${PGUSER:=postgres}"; : "\${PGDATABASE:=postgres}"; : "\${PGPASSWORD:=postgres}"
export PGHOST PGPORT PGUSER PGDATABASE PGPASSWORD
parent='dddddddd-dddd-4ddd-8ddd-dddddddddddd'
command='cccccccc-cccc-4ccc-8ccc-cccccccccccc'
psql -v ON_ERROR_STOP=1 <<SQL
SELECT henvalt_test.seed_initial('$parent') AS request_id \\gset
SELECT henvalt_test.mark_pre_provider_failure(:'request_id');
SQL
first_log="$(mktemp)"; second_log="$(mktemp)"
PGAPPNAME=same-command-first psql -v ON_ERROR_STOP=1 >"$first_log" 2>&1 <<SQL &
BEGIN;
SELECT id FROM henvalt_test.interventions WHERE id='$parent' FOR UPDATE;
SELECT pg_sleep(1.2);
SELECT henvalt_test.create_retry_generation('$parent','$command') AS request_id;
COMMIT;
SQL
first_pid=$!
ready=0
for _ in $(seq 1 100); do
  active=$(psql -Atqc "SELECT count(*) FROM pg_stat_activity WHERE application_name='same-command-first' AND query LIKE '%pg_sleep%';")
  if [[ "$active" == "1" ]]; then ready=1; break; fi
  sleep 0.03
done
if [[ "$ready" != "1" ]]; then cat "$first_log"; kill "$first_pid" 2>/dev/null || true; echo "first same-command session missed barrier" >&2; exit 1; fi
PGAPPNAME=same-command-second psql -v ON_ERROR_STOP=1 >"$second_log" 2>&1 <<SQL
SELECT henvalt_test.create_retry_generation('$parent','$command') AS request_id;
SQL
wait "$first_pid"
first_id=$(grep -Eo '[0-9a-f-]{36}' "$first_log" | tail -1)
second_id=$(grep -Eo '[0-9a-f-]{36}' "$second_log" | tail -1)
[[ -n "$first_id" && "$first_id" == "$second_id" ]] || { echo "same retry command did not return the same request id" >&2; cat "$first_log" "$second_log"; exit 1; }
count=$(psql -Atqc "SELECT count(*) FROM henvalt_test.delivery_requests WHERE intervention_id='$parent';")
[[ "$count" == "2" ]] || { echo "same command created more than one generation" >&2; exit 1; }
echo "concurrent duplicate retry-command idempotency passed"

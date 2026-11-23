#!/usr/bin/env bash
set -euo pipefail
: "\${PGHOST:=127.0.0.1}"; : "\${PGPORT:=5432}"; : "\${PGUSER:=postgres}"; : "\${PGDATABASE:=postgres}"; : "\${PGPASSWORD:=postgres}"
export PGHOST PGPORT PGUSER PGDATABASE PGPASSWORD
parent='eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee'
command_a='aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa1'
command_b='bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbb2'
psql -v ON_ERROR_STOP=1 <<SQL
SELECT henvalt_test.seed_initial('$parent') AS request_id \\gset
SELECT henvalt_test.mark_pre_provider_failure(:'request_id');
SQL
first_log="$(mktemp)"; second_log="$(mktemp)"
PGAPPNAME=gen-first psql -v ON_ERROR_STOP=1 >"$first_log" 2>&1 <<SQL &
BEGIN;
SELECT id FROM henvalt_test.interventions WHERE id='$parent' FOR UPDATE;
SELECT pg_sleep(1.2);
SELECT henvalt_test.create_retry_generation('$parent','$command_a');
COMMIT;
SQL
first_pid=$!
ready=0
for _ in $(seq 1 100); do
  active=$(psql -Atqc "SELECT count(*) FROM pg_stat_activity WHERE application_name='gen-first' AND query LIKE '%pg_sleep%';")
  if [[ "$active" == "1" ]]; then ready=1; break; fi
  sleep 0.03
done
if [[ "$ready" != "1" ]]; then cat "$first_log"; kill "$first_pid" 2>/dev/null || true; echo "first generation session missed barrier" >&2; exit 1; fi
if PGAPPNAME=gen-second psql -v ON_ERROR_STOP=1 >"$second_log" 2>&1 <<SQL
SELECT henvalt_test.create_retry_generation('$parent','$command_b');
SQL
then
  echo "second concurrent retry command unexpectedly created another generation" >&2
  cat "$second_log"
  kill "$first_pid" 2>/dev/null || true
  exit 1
fi
wait "$first_pid"
count=$(psql -Atqc "SELECT count(*) FROM henvalt_test.delivery_requests WHERE intervention_id='$parent';")
[[ "$count" == "2" ]] || { echo "expected exactly two generations, found $count" >&2; cat "$first_log" "$second_log"; exit 1; }
echo "concurrent retry-generation serialization passed"

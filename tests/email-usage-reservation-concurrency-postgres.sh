#!/usr/bin/env bash
set -euo pipefail
: "${PGHOST:=127.0.0.1}"
: "${PGPORT:=5432}"
: "${PGUSER:=postgres}"
: "${PGDATABASE:=postgres}"
: "${PGPASSWORD:=postgres}"
export PGHOST PGPORT PGUSER PGDATABASE PGPASSWORD
tenant='55555555-5555-4555-8555-555555555555'
r1='66666666-6666-4666-8666-666666666661'
r2='66666666-6666-4666-8666-666666666662'
psql -v ON_ERROR_STOP=1 <<SQL
INSERT INTO henvalt.billing_accounts(tenant_id,status,test_mode,activated_at,monthly_email_limit)
VALUES ('$tenant','PENDING',true,now()-interval '1 day',5);
INSERT INTO henvalt.email_usage_measurements(tenant_id,delivery_attempt_id)
SELECT '$tenant',gen_random_uuid() FROM generate_series(1,4);
INSERT INTO henvalt.delivery_requests(id,tenant_id) VALUES ('$r1','$tenant'),('$r2','$tenant');
SQL
first_log="$(mktemp)"
second_log="$(mktemp)"
PGAPPNAME=quota-first psql -v ON_ERROR_STOP=1 >"$first_log" 2>&1 <<SQL &
BEGIN;
UPDATE henvalt.delivery_requests SET status='UNKNOWN' WHERE id='$r1';
SELECT pg_sleep(1.5);
COMMIT;
SQL
first_pid=$!
ready=0
for _ in $(seq 1 100); do
  active=$(psql -Atqc "SELECT count(*) FROM pg_stat_activity WHERE application_name='quota-first' AND query LIKE '%pg_sleep%';")
  if [[ "$active" == "1" ]]; then ready=1; break; fi
  sleep 0.03
done
if [[ "$ready" != "1" ]]; then
  cat "$first_log"
  kill "$first_pid" 2>/dev/null || true
  echo "first session did not reach the reservation-held barrier" >&2
  exit 1
fi
if PGAPPNAME=quota-second psql -v ON_ERROR_STOP=1 >"$second_log" 2>&1 <<SQL
UPDATE henvalt.delivery_requests SET status='UNKNOWN' WHERE id='$r2';
SQL
then
  echo "second independent claim unexpectedly passed the final quota slot" >&2
  cat "$second_log"
  wait "$first_pid"
  exit 1
fi
wait "$first_pid"
if ! grep -q 'HENVALT email usage limit reached' "$second_log"; then
  cat "$second_log"
  echo "second claim failed for an unexpected reason" >&2
  exit 1
fi
psql -v ON_ERROR_STOP=1 <<SQL
DO \$verify\$
BEGIN
 IF (SELECT count(*) FROM henvalt.email_usage_reservations
      WHERE tenant_id='$tenant' AND status='RESERVED') <> 1 THEN
   RAISE EXCEPTION 'expected exactly one outstanding reservation';
 END IF;
 IF (SELECT status FROM henvalt.delivery_requests WHERE id='$r1') <> 'UNKNOWN'
    OR (SELECT status FROM henvalt.delivery_requests WHERE id='$r2') <> 'PENDING' THEN
   RAISE EXCEPTION 'concurrent claim state is inconsistent';
 END IF;
 UPDATE henvalt.delivery_requests SET status='UNKNOWN' WHERE id='$r1';
 IF (SELECT count(*) FROM henvalt.email_usage_reservations
      WHERE delivery_request_id='$r1') <> 1 THEN
   RAISE EXCEPTION 'duplicate retry created a second reservation';
 END IF;
END
\$verify\$;
SQL
rm -f "$first_log" "$second_log"
echo "two-session email quota reservation concurrency acceptance passed"

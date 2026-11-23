#!/usr/bin/env bash
set -euo pipefail
: "${PGHOST:=127.0.0.1}"
: "${PGPORT:=5432}"
: "${PGUSER:=postgres}"
: "${PGDATABASE:=postgres}"
: "${PGPASSWORD:=postgres}"
export PGHOST PGPORT PGUSER PGDATABASE PGPASSWORD

tenant='99999999-9999-4999-8999-999999999999'
delivery='aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'
failure_attempt='bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'
accepted_attempt='cccccccc-cccc-4ccc-8ccc-cccccccccccc'

psql -v ON_ERROR_STOP=1 <<SQL
INSERT INTO henvalt.billing_accounts(tenant_id,status,test_mode,activated_at,monthly_email_limit)
VALUES ('$tenant','PENDING',true,now()-interval '1 day',10);
INSERT INTO henvalt.delivery_requests(id,tenant_id) VALUES ('$delivery','$tenant');
UPDATE henvalt.delivery_requests SET status='UNKNOWN' WHERE id='$delivery';
SQL

failure_log="$(mktemp)"
accepted_log="$(mktemp)"
PGAPPNAME=quota-settlement-failure psql -v ON_ERROR_STOP=1 >"$failure_log" 2>&1 <<SQL &
BEGIN;
INSERT INTO henvalt.delivery_attempts(id,tenant_id,delivery_request_id,state,provider_status_code)
VALUES ('$failure_attempt','$tenant','$delivery','FAILED',400);
SELECT pg_sleep(0.25);
COMMIT;
SQL
failure_pid=$!

PGAPPNAME=quota-settlement-accepted psql -v ON_ERROR_STOP=1 >"$accepted_log" 2>&1 <<SQL &
BEGIN;
INSERT INTO henvalt.delivery_attempts(id,tenant_id,delivery_request_id,state,provider_status_code)
VALUES ('$accepted_attempt','$tenant','$delivery','ACCEPTED',202);
SELECT pg_sleep(0.25);
COMMIT;
SQL
accepted_pid=$!

if ! wait "$failure_pid"; then cat "$failure_log"; cat "$accepted_log"; exit 1; fi
if ! wait "$accepted_pid"; then cat "$failure_log"; cat "$accepted_log"; exit 1; fi

psql -v ON_ERROR_STOP=1 <<SQL
DO \$verify\$
DECLARE
  v_status text;
  v_released integer;
  v_consumed integer;
BEGIN
  SELECT status INTO v_status
    FROM henvalt.email_usage_reservations
   WHERE delivery_request_id='$delivery';
  IF v_status IS DISTINCT FROM 'CONSUMED' THEN
    RAISE EXCEPTION 'late/concurrent acceptance lost to rejection: final reservation status %',v_status;
  END IF;

  SELECT count(*) FILTER (WHERE event_type='RELEASED'),
         count(*) FILTER (WHERE event_type='CONSUMED')
    INTO v_released,v_consumed
    FROM henvalt.email_usage_reservation_events
   WHERE delivery_request_id='$delivery';

  IF v_consumed < 1 OR v_released > 1 THEN
    RAISE EXCEPTION 'concurrent settlement evidence is invalid: released %, consumed %',v_released,v_consumed;
  END IF;

  IF (SELECT count(*) FROM henvalt.email_usage_measurements
       WHERE tenant_id='$tenant') <> 1 THEN
    RAISE EXCEPTION 'accepted provider attempt must be measured exactly once';
  END IF;
END
\$verify\$;
SQL

rm -f "$failure_log" "$accepted_log"
echo "concurrent provider rejection/acceptance settlement acceptance passed"

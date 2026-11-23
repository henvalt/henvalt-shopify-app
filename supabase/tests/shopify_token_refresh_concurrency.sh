#!/usr/bin/env bash
set -euo pipefail

: "${PGHOST:=127.0.0.1}"
: "${PGPORT:=5432}"
: "${PGUSER:=postgres}"
: "${PGDATABASE:=postgres}"
export PGHOST PGPORT PGUSER PGDATABASE

psql_cmd=(psql -X -qAt -v ON_ERROR_STOP=1)
tmp="$(mktemp -d)"
gate="$tmp/start"
cleanup() {
  rm -rf "$tmp"
}
trap cleanup EXIT

# Reset the fixture left by the preceding SQL contract test.
"${psql_cmd[@]}" -c "
  UPDATE henvalt.shopify_connections
  SET active=true,
      reauth_required_at=NULL,
      access_token_expires_at=clock_timestamp()-interval '1 minute',
      refresh_token_expires_at=clock_timestamp()+interval '80 days',
      token_refresh_lease_until=NULL,
      token_refresh_lease_id=NULL,
      token_refresh_last_error=NULL
  WHERE shop_domain='demo.myshopify.com';
"

# Hold the first claimant inside its UPDATE after it has acquired the
# per-shop advisory lock. The second independent psql session must overlap it.
"${psql_cmd[@]}" <<'SQL'
CREATE OR REPLACE FUNCTION henvalt.test_delay_token_refresh_claim()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  IF NEW.token_refresh_lease_id IS DISTINCT FROM OLD.token_refresh_lease_id
     AND NEW.token_refresh_lease_id IS NOT NULL THEN
    PERFORM pg_sleep(3);
  END IF;
  RETURN NEW;
END;
$$;
DROP TRIGGER IF EXISTS test_delay_token_refresh_claim ON henvalt.shopify_connections;
CREATE TRIGGER test_delay_token_refresh_claim
BEFORE UPDATE OF token_refresh_lease_id ON henvalt.shopify_connections
FOR EACH ROW EXECUTE FUNCTION henvalt.test_delay_token_refresh_claim();
SQL

wait_for_gate() {
  while [[ ! -e "$gate" ]]; do sleep 0.01; done
}
(
  wait_for_gate
  "${psql_cmd[@]}" -c "SELECT henvalt.claim_shopify_token_refresh('demo.myshopify.com',true);" > "$tmp/claim-a"
) &
pid_a=$!
(
  wait_for_gate
  "${psql_cmd[@]}" -c "SELECT henvalt.claim_shopify_token_refresh('demo.myshopify.com',true);" > "$tmp/claim-b"
) &
pid_b=$!
touch "$gate"
wait "$pid_a"
wait "$pid_b"

lease_id="$(python3 - "$tmp/claim-a" "$tmp/claim-b" <<'PY'
import json, pathlib, sys
results = [json.loads(pathlib.Path(p).read_text().strip()) for p in sys.argv[1:]]
winners = [r for r in results if r.get("claimed") is True]
losers = [r for r in results if r.get("claimed") is False]
assert len(winners) == 1, f"expected exactly one concurrent winner, got {results}"
assert len(losers) == 1 and losers[0].get("reason") == "REFRESH_ALREADY_IN_PROGRESS", results
lease = winners[0].get("lease_id")
assert isinstance(lease, str) and len(lease) == 36, winners[0]
print(lease)
PY
)"

stored_lease="$("${psql_cmd[@]}" -c "SELECT token_refresh_lease_id FROM henvalt.shopify_connections WHERE shop_domain='demo.myshopify.com';")"
[[ "$stored_lease" == "$lease_id" ]] || { echo "concurrent winner lease does not match stored lease" >&2; exit 1; }

# Prove expiry is checked after waiting for the per-shop lock, not against
# PostgreSQL now() (transaction start time). The completion transaction starts
# while the lease is live, waits behind a lock holder, then resumes after expiry.
"${psql_cmd[@]}" -c "UPDATE henvalt.shopify_connections SET token_refresh_lease_until=clock_timestamp()+interval '5 seconds' WHERE shop_domain='demo.myshopify.com';"
"${psql_cmd[@]}" -c "BEGIN; SELECT pg_advisory_xact_lock(hashtextextended('demo.myshopify.com:shopify-token-refresh',0)); SELECT 'LOCK_HELD'; SELECT pg_sleep(8); COMMIT;" > "$tmp/lock-holder" &
holder_pid=$!
for _ in $(seq 1 200); do
  if grep -q LOCK_HELD "$tmp/lock-holder" 2>/dev/null; then break; fi
  sleep 0.02
done
grep -q LOCK_HELD "$tmp/lock-holder" || { echo "lock holder did not acquire advisory lock" >&2; exit 1; }

PGAPPNAME=henvalt-lease-expiry-test "${psql_cmd[@]}" -c "SELECT henvalt.complete_shopify_token_refresh('demo.myshopify.com','late-access-token-01234567890123456789','late-refresh-token-01234567890123456789',3600,7776000,'$lease_id'::uuid);" > "$tmp/late-completion" &
completion_pid=$!
waiting=0
for _ in $(seq 1 200); do
  waiting="$("${psql_cmd[@]}" -c "SELECT count(*) FROM pg_stat_activity WHERE application_name='henvalt-lease-expiry-test' AND wait_event_type='Lock';")"
  [[ "$waiting" == "1" ]] && break
  sleep 0.02
done
[[ "$waiting" == "1" ]] || { echo "completion transaction did not block behind the test lock" >&2; exit 1; }
sleep 6
wait "$holder_pid"
wait "$completion_pid"

python3 - "$tmp/late-completion" "$lease_id" <<'PY'
import json, pathlib, sys
result = json.loads(pathlib.Path(sys.argv[1]).read_text().strip())
assert result.get("reason") == "STALE_REFRESH_LEASE", result
PY

remaining_lease="$("${psql_cmd[@]}" -c "SELECT token_refresh_lease_id FROM henvalt.shopify_connections WHERE shop_domain='demo.myshopify.com';")"
[[ "$remaining_lease" == "$lease_id" ]] || { echo "expired completion changed the current lease" >&2; exit 1; }

"${psql_cmd[@]}" <<'SQL'
DROP TRIGGER IF EXISTS test_delay_token_refresh_claim ON henvalt.shopify_connections;
DROP FUNCTION IF EXISTS henvalt.test_delay_token_refresh_claim();
SQL

echo "Concurrent claim exclusivity and post-lock lease-expiry checks passed."

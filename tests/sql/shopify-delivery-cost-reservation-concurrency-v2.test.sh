#!/usr/bin/env bash
set -euo pipefail

export PGPASSWORD="${PGPASSWORD:-postgres}"
psql_cmd=(psql -h 127.0.0.1 -U postgres -d postgres -v ON_ERROR_STOP=1)

set +e
"${psql_cmd[@]}" -c "SELECT henvalt.test_cost_reservation_race_v2('store-a.myshopify.com')" >/tmp/henvalt-race-a.log 2>&1 &
pid_a=$!
"${psql_cmd[@]}" -c "SELECT henvalt.test_cost_reservation_race_v2('store-b.myshopify.com')" >/tmp/henvalt-race-b.log 2>&1 &
pid_b=$!
wait "$pid_a"
status_a=$?
wait "$pid_b"
status_b=$?
set -e

if [[ "$status_a" -eq 0 && "$status_b" -eq 0 ]]; then
  cat /tmp/henvalt-race-a.log /tmp/henvalt-race-b.log
  echo "Checkout and pixel stores both exceeded the shared merchant-wide cap." >&2
  exit 1
fi
if [[ "$status_a" -ne 0 && "$status_b" -ne 0 ]]; then
  cat /tmp/henvalt-race-a.log /tmp/henvalt-race-b.log
  echo "Both reservation paths failed; expected exactly one winner." >&2
  exit 1
fi

if [[ "$status_a" -ne 0 ]]; then
  grep -q "merchant monetary usage cap would be exceeded" /tmp/henvalt-race-a.log || {
    cat /tmp/henvalt-race-a.log
    echo "Checkout path failed for a reason other than the serialized merchant cap." >&2
    exit 1
  }
else
  grep -q "merchant monetary usage cap would be exceeded" /tmp/henvalt-race-b.log || {
    cat /tmp/henvalt-race-b.log
    echo "Pixel path failed for a reason other than the serialized merchant cap." >&2
    exit 1
  }
fi

checkout_count=$("${psql_cmd[@]}" -Atc "SELECT count(*) FROM henvalt.shopify_delivery_cost_reservations_v2 r JOIN henvalt.shopify_recovery_send_attempt_v2 a ON a.id=r.send_attempt_id WHERE r.tenant_id='00000000-0000-4000-8000-000000000001' AND a.idempotency_key IN ('race-store-a-myshopify-com','race-store-b-myshopify-com') AND r.status='RESERVED'")
pixel_count=$("${psql_cmd[@]}" -Atc "SELECT count(*) FROM henvalt.shopify_pixel_delivery_cost_reservations_v2 r JOIN henvalt.shopify_pixel_send_attempts_v2 a ON a.id=r.pixel_send_attempt_id WHERE r.tenant_id='00000000-0000-4000-8000-000000000001' AND a.idempotency_key IN ('race-pixel-store-b-myshopify-com') AND r.status='RESERVED'")
total=$((checkout_count+pixel_count))
if [[ "$total" != "1" ]]; then
  cat /tmp/henvalt-race-a.log /tmp/henvalt-race-b.log
  echo "Expected exactly one checkout-or-pixel reservation to win the cap race; got $total." >&2
  exit 1
fi

"${psql_cmd[@]}" -c "DROP FUNCTION henvalt.test_cost_reservation_race_v2(text); UPDATE henvalt.billing_accounts SET usage_cap_amount=10,monthly_email_limit=10 WHERE tenant_id='00000000-0000-4000-8000-000000000001';"
echo "shopify_checkout_vs_pixel_cost_reservation_concurrency_v2_passed"

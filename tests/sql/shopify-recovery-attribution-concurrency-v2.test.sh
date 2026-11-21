#!/usr/bin/env bash
set -euo pipefail
export PGPASSWORD="${PGPASSWORD:-postgres}"
psql_cmd=(psql -h 127.0.0.1 -U postgres -d postgres -v ON_ERROR_STOP=1)

# Both independent sessions enter the test-only insert barrier before the
# unique opportunity constraint lets either transaction finish.
set +e
"${psql_cmd[@]}" -Atc "SELECT henvalt.evaluate_shopify_recovery_attribution_v2(order_a_id) FROM henvalt.test_attribution_race_fixture_v2" >/tmp/henvalt-attribution-race-a.log 2>&1 &
pid_a=$!
"${psql_cmd[@]}" -Atc "SELECT henvalt.evaluate_shopify_recovery_attribution_v2(order_b_id) FROM henvalt.test_attribution_race_fixture_v2" >/tmp/henvalt-attribution-race-b.log 2>&1 &
pid_b=$!
wait "$pid_a"; status_a=$?
wait "$pid_b"; status_b=$?
set -e
if [[ "$status_a" -ne 0 || "$status_b" -ne 0 ]]; then
  cat /tmp/henvalt-attribution-race-a.log /tmp/henvalt-attribution-race-b.log
  echo "Concurrent attribution evaluator session failed." >&2
  exit 1
fi

combined_output="$(cat /tmp/henvalt-attribution-race-a.log /tmp/henvalt-attribution-race-b.log)"
accepted_count="$(grep -c '"accepted": true' <<<"$combined_output" || true)"
rejected_count="$(grep -c '"accepted": false' <<<"$combined_output" || true)"
if [[ "$accepted_count" != "1" || "$rejected_count" != "1" ]] ||
   ! grep -q 'OPPORTUNITY_ALREADY_ATTRIBUTED' <<<"$combined_output"; then
  printf '%s\n' "$combined_output"
  echo "Expected one accepted winner and one explicit OPPORTUNITY_ALREADY_ATTRIBUTED loser." >&2
  exit 1
fi

result=$("${psql_cmd[@]}" -Atc "
  SELECT
    count(*) FILTER (WHERE a.opportunity_id=f.opportunity_id)::text || ':' ||
    count(DISTINCT a.order_identity_id)::text || ':' ||
    count(DISTINCT a.id)::text || ':' ||
    (SELECT count(*) FROM henvalt.shopify_recovery_fee_measurements_v2 fee
      JOIN henvalt.shopify_recovery_attributions_v2 attr
        ON attr.id=fee.attribution_id
      JOIN henvalt.test_attribution_race_fixture_v2 fx
        ON fx.opportunity_id=attr.opportunity_id)::text
  FROM henvalt.test_attribution_race_fixture_v2 f
  LEFT JOIN henvalt.shopify_recovery_attributions_v2 a
    ON a.opportunity_id=f.opportunity_id
  GROUP BY f.opportunity_id
")
if [[ "$result" != "1:1:1:1" ]]; then
  cat /tmp/henvalt-attribution-race-a.log /tmp/henvalt-attribution-race-b.log
  echo "Expected one attribution, one winning order, one attribution ID and one fee row; got $result." >&2
  exit 1
fi

winner_code=$("${psql_cmd[@]}" -Atc "
  SELECT count(*) FROM henvalt.test_attribution_race_fixture_v2 f
  JOIN henvalt.shopify_recovery_attributions_v2 a
    ON a.opportunity_id=f.opportunity_id
  WHERE a.order_identity_id IN (f.order_a_id,f.order_b_id)
")
if [[ "$winner_code" != "1" ]]; then
  echo "Winning attribution did not belong to one of the two competing orders." >&2
  exit 1
fi

"${psql_cmd[@]}" <<'SQL'
DROP TRIGGER test_attribution_race_barrier_v2 ON henvalt.shopify_recovery_attributions_v2;
DROP FUNCTION henvalt.test_attribution_race_barrier_v2();
DELETE FROM henvalt.shopify_recovery_fee_measurements_v2 fee
USING henvalt.shopify_recovery_attributions_v2 a,
      henvalt.test_attribution_race_fixture_v2 f
WHERE fee.attribution_id=a.id AND a.opportunity_id=f.opportunity_id;
DELETE FROM henvalt.shopify_recovery_attributions_v2 a
USING henvalt.test_attribution_race_fixture_v2 f
WHERE a.opportunity_id=f.opportunity_id;
DELETE FROM henvalt.shopify_delivery_cost_reservations_v2
WHERE send_attempt_id IN (
  SELECT id FROM henvalt.shopify_recovery_send_attempt_v2
  WHERE idempotency_key='attribution-race-send'
);
DELETE FROM henvalt.shopify_recovery_send_attempt_v2
WHERE idempotency_key='attribution-race-send';
DELETE FROM henvalt.shopify_recovery_intervention_v2
WHERE step_number=3 AND opportunity_id IN (
  SELECT opportunity_id FROM henvalt.test_attribution_race_fixture_v2
);
DELETE FROM henvalt.shopify_order_identity_v2 o
USING henvalt.test_attribution_race_fixture_v2 f
WHERE o.id=f.order_b_id;
DELETE FROM henvalt.shopify_mailer_provider_registry_v2
WHERE provider_account_key='henvalt-attribution-race-provider';
DELETE FROM henvalt.test_attribution_race_fixture_v2;
SQL
echo "shopify_recovery_attribution_concurrency_v2_passed"

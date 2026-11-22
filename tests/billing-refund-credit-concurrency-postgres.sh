#!/usr/bin/env bash
set -euo pipefail

psql_cmd=(psql -X -qAt -h 127.0.0.1 -U postgres -d postgres -v ON_ERROR_STOP=1)
tenant="aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaa0222"
connection="bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbb0222"
credit_ledger="eeeeeeee-eeee-4eee-8eee-eeeeeeee0221"
recovery_ledger_a="eeeeeeee-eeee-4eee-8eee-eeeeeeee0222"
recovery_ledger_b="eeeeeeee-eeee-4eee-8eee-eeeeeeee0223"
credit_measurement="cccccccc-cccc-4ccc-8ccc-cccccccc0221"
recovery_measurement_a="dddddddd-dddd-4ddd-8ddd-dddddddd0221"
recovery_measurement_b="dddddddd-dddd-4ddd-8ddd-dddddddd0222"
shop="billing-race.myshopify.com"

"${psql_cmd[@]}" <<SQL
INSERT INTO henvalt.tenants(id,status,default_currency)
VALUES ('$tenant','ACTIVE','USD');
INSERT INTO henvalt.shopify_connections(id,tenant_id,active,shop_domain)
VALUES ('$connection','$tenant',true,'$shop');
INSERT INTO henvalt.billing_accounts(
  tenant_id,provider,plan_key,recurring_amount,henvalt_percentage,
  usage_cap_amount,currency,usage_line_item_id,status,test_mode,activated_at
) VALUES (
  '$tenant','SHOPIFY','STARTER',0,10,100,'USD',
  'gid://shopify/AppSubscriptionLineItem/billing-race','ACTIVE',true,now()-interval '1 day'
);
INSERT INTO henvalt.revenue_ledger(
  id,tenant_id,entry_type,amount,currency,attribution_confidence,billable,billing_status,metadata
) VALUES
  ('$credit_ledger','$tenant','ADJUSTMENT',-30,'USD','CONFIRMED',true,'MEASURED','{}'),
  ('$recovery_ledger_a','$tenant','RECOVERY',100,'USD','CONFIRMED',true,'MEASURED','{}'),
  ('$recovery_ledger_b','$tenant','RECOVERY',100,'USD','CONFIRMED',true,'MEASURED','{}');
INSERT INTO henvalt.billing_measurements(
  id,tenant_id,billing_period_id,ledger_entry_id,recovered_revenue,
  henvalt_percentage,henvalt_fee,currency,status,created_at
) VALUES
  ('$credit_measurement','$tenant',gen_random_uuid(),'$credit_ledger',-30,10,-3,'USD','MEASURED',now()-interval '1 hour'),
  ('$recovery_measurement_a','$tenant',gen_random_uuid(),'$recovery_ledger_a',100,10,10,'USD','MEASURED',now()),
  ('$recovery_measurement_b','$tenant',gen_random_uuid(),'$recovery_ledger_b',100,10,10,'USD','MEASURED',now()+interval '1 second');
SQL

tmp_a="$(mktemp)"
tmp_b="$(mktemp)"
cleanup() { rm -f "$tmp_a" "$tmp_b"; }
trap cleanup EXIT

# Worker A claims the first recovery and deliberately holds its transaction
# open after allocating the credit, giving worker B a deterministic lock race.
"${psql_cmd[@]}" -c "BEGIN; SELECT henvalt.control_plane_claim_billing_usage('$shop'); SELECT pg_sleep(2); COMMIT;" >"$tmp_a" &
pid_a=$!

for _ in $(seq 1 40); do
  if grep -q '"chargeId"' "$tmp_a"; then break; fi
  sleep 0.1
done
if ! grep -q '"chargeId"' "$tmp_a"; then
  echo "worker A did not claim a charge" >&2
  exit 1
fi

"${psql_cmd[@]}" -c "SELECT henvalt.control_plane_claim_billing_usage('$shop');" >"$tmp_b" &
pid_b=$!
wait "$pid_b"
wait "$pid_a"

if ! grep -Eq '"amount":[[:space:]]*7([.]0+)?' "$tmp_a"; then
  echo "worker A did not receive the 3-unit credit offset: $(cat "$tmp_a")" >&2
  exit 1
fi
if ! grep -Eq '"amount":[[:space:]]*10([.]0+)?' "$tmp_b"; then
  echo "worker B incorrectly reused or lost the locked credit: $(cat "$tmp_b")" >&2
  exit 1
fi

offsets=$("${psql_cmd[@]}" -c "SELECT COALESCE(sum(amount),0) FROM henvalt.billing_measurement_credit_offsets WHERE tenant_id='$tenant';")
charges=$("${psql_cmd[@]}" -c "SELECT COALESCE(sum(amount),0) FROM henvalt.billing_usage_charges WHERE tenant_id='$tenant';")
charge_count=$("${psql_cmd[@]}" -c "SELECT count(*) FROM henvalt.billing_usage_charges WHERE tenant_id='$tenant';")
if [[ "$offsets" != "3.0000" && "$offsets" != "3" ]]; then
  echo "expected exactly 3 allocated credit, got $offsets" >&2
  exit 1
fi
if [[ "$charges" != "17.0000" && "$charges" != "17" ]]; then
  echo "expected net usage charges totaling 17, got $charges" >&2
  exit 1
fi
if [[ "$charge_count" != "2" ]]; then
  echo "expected exactly two usage charges, got $charge_count" >&2
  exit 1
fi

echo "BILLING_REFUND_CREDIT_CONCURRENCY_ACCEPTANCE_PASSED"

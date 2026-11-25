\set ON_ERROR_STOP on

INSERT INTO henvalt.tenants(id,status)
VALUES ('abababab-abab-4bab-8bab-abababababab','ACTIVE')
ON CONFLICT (id) DO UPDATE SET status = EXCLUDED.status;

INSERT INTO henvalt.shopify_connections(id,tenant_id,active,shop_domain,reauth_required_at)
VALUES ('acacacac-acac-4cac-8cac-acacacacacac',
        'abababab-abab-4bab-8bab-abababababab',
        true,'billing-egress.myshopify.com',NULL)
ON CONFLICT (id) DO UPDATE SET active = true, reauth_required_at = NULL;

INSERT INTO henvalt.billing_accounts(
  tenant_id,provider,plan_key,recurring_amount,henvalt_percentage,
  usage_cap_amount,currency,usage_line_item_id,status,test_mode
) VALUES (
  'abababab-abab-4bab-8bab-abababababab','SHOPIFY','STARTER',
  0,5,100,'USD','gid://shopify/AppSubscriptionLineItem/egress-1','ACTIVE',true
)
ON CONFLICT (tenant_id) DO UPDATE
SET provider=EXCLUDED.provider, usage_line_item_id=EXCLUDED.usage_line_item_id,
    status='ACTIVE', test_mode=true;

INSERT INTO henvalt.billing_measurements(
  id,tenant_id,billing_period_id,ledger_entry_id,recovered_revenue,
  henvalt_percentage,henvalt_fee,currency,status
) VALUES (
  'adadadad-adad-4dad-8dad-adadadadadad',
  'abababab-abab-4bab-8bab-abababababab',
  'aeaeaeae-aeae-4eae-8eae-aeaeaeaeaeae',
  'afafafaf-afaf-4faf-8faf-afafafafafaf',
  145,5,7.25,'USD','MEASURED'
)
ON CONFLICT (id) DO NOTHING;

INSERT INTO henvalt.billing_usage_charges(
  id,tenant_id,billing_measurement_id,provider,idempotency_key,
  amount,currency,status,attempt_count,attempted_at
) VALUES (
  'babababa-baba-4bab-8bab-babababababa',
  'abababab-abab-4bab-8bab-abababababab',
  'adadadad-adad-4dad-8dad-adadadadadad',
  'SHOPIFY','henvalt-egress-authorization-test',7.25,'USD','PENDING',1,now()
)
ON CONFLICT (id) DO UPDATE
SET status='PENDING',attempt_count=1,idempotency_key='henvalt-egress-authorization-test';

DO $egress_authorization$
DECLARE
  v_result jsonb;
BEGIN
  SELECT henvalt.control_plane_authorize_billing_usage_egress(
    'billing-egress.myshopify.com',
    'babababa-baba-4bab-8bab-babababababa',
    'henvalt-egress-authorization-test',
    'gid://shopify/AppSubscriptionLineItem/egress-1',
    1
  ) INTO v_result;

  IF v_result->>'authorized' IS DISTINCT FROM 'true' THEN
    RAISE EXCEPTION 'ACTIVE_TEST_SUBSCRIPTION_NOT_AUTHORIZED: %',v_result;
  END IF;

  -- Cancellation committed after the worker's initial claim must be observed
  -- by the final egress gate, before any external Shopify request.
  UPDATE henvalt.billing_accounts
     SET status='CANCELLED',cancelled_at=now()
   WHERE tenant_id='abababab-abab-4bab-8bab-abababababab';

  SELECT henvalt.control_plane_authorize_billing_usage_egress(
    'billing-egress.myshopify.com',
    'babababa-baba-4bab-8bab-babababababa',
    'henvalt-egress-authorization-test',
    'gid://shopify/AppSubscriptionLineItem/egress-1',
    1
  ) INTO v_result;

  IF v_result->>'authorized' IS DISTINCT FROM 'false'
     OR v_result->>'reason' IS DISTINCT FROM 'BILLING_SUBSCRIPTION_NOT_ACTIVE' THEN
    RAISE EXCEPTION 'CANCELLED_SUBSCRIPTION_PASSED_FINAL_EGRESS_GATE: %',v_result;
  END IF;

  UPDATE henvalt.billing_accounts
     SET status='ACTIVE'
   WHERE tenant_id='abababab-abab-4bab-8bab-abababababab';

  UPDATE henvalt.billing_usage_charges
     SET attempt_count=2,attempted_at=now()
   WHERE id='babababa-baba-4bab-8bab-babababababa';

  SELECT henvalt.control_plane_authorize_billing_usage_egress(
    'billing-egress.myshopify.com',
    'babababa-baba-4bab-8bab-babababababa',
    'henvalt-egress-authorization-test',
    'gid://shopify/AppSubscriptionLineItem/egress-1',
    1
  ) INTO v_result;

  IF v_result->>'authorized' IS DISTINCT FROM 'false'
     OR v_result->>'reason' IS DISTINCT FROM 'CHARGE_CLAIM_STALE' THEN
    RAISE EXCEPTION 'STALE_WORKER_PASSED_FINAL_EGRESS_GATE: %',v_result;
  END IF;

  SELECT henvalt.control_plane_authorize_billing_usage_egress(
    'billing-egress.myshopify.com',
    'babababa-baba-4bab-8bab-babababababa',
    'henvalt-egress-authorization-test',
    'gid://shopify/AppSubscriptionLineItem/changed-line-item',
    2
  ) INTO v_result;

  IF v_result->>'authorized' IS DISTINCT FROM 'false'
     OR v_result->>'reason' IS DISTINCT FROM 'SUBSCRIPTION_LINE_ITEM_CHANGED' THEN
    RAISE EXCEPTION 'CHANGED_SUBSCRIPTION_LINE_ITEM_PASSED_FINAL_EGRESS_GATE: %',v_result;
  END IF;

  RAISE NOTICE 'BILLING FINAL EGRESS AUTHORIZATION ACCEPTANCE PASSED';
END;
$egress_authorization$;

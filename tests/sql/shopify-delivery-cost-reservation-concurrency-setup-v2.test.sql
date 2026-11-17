-- Disposable-database setup for a two-session merchant-wide reservation race.
\set ON_ERROR_STOP on
CREATE OR REPLACE FUNCTION henvalt.test_cost_reservation_race_v2(p_shop_domain text)
RETURNS uuid
LANGUAGE plpgsql
AS $race$
DECLARE
  v_tenant uuid:='00000000-0000-4000-8000-000000000001';
  v_connection uuid; v_customer uuid; v_opportunity uuid; v_provider text;
  v_intervention uuid; v_attempt uuid;
BEGIN
  IF p_shop_domain NOT IN ('store-a.myshopify.com','store-b.myshopify.com') THEN
    RAISE EXCEPTION 'Unexpected race-test store';
  END IF;
  SELECT id INTO v_connection FROM henvalt.shopify_connections
    WHERE tenant_id=v_tenant AND shop_domain=p_shop_domain;
  SELECT id INTO v_customer FROM henvalt.shopify_customer_identity_v2
    WHERE tenant_id=v_tenant AND shopify_connection_id=v_connection
      AND external_customer_reference='12345';
  SELECT id INTO v_opportunity FROM henvalt.shopify_recovery_opportunity_v2
    WHERE tenant_id=v_tenant AND shopify_connection_id=v_connection
    ORDER BY created_at DESC LIMIT 1;
  SELECT provider_account_key INTO v_provider FROM henvalt.shopify_mailer_provider_registry_v2
    WHERE tenant_id=v_tenant AND status='ACTIVE'
    AND email_unit_cost_amount=0.01 AND email_unit_cost_currency='USD'
    ORDER BY created_at LIMIT 1;
  IF v_connection IS NULL OR v_customer IS NULL OR v_opportunity IS NULL OR v_provider IS NULL THEN
    RAISE EXCEPTION 'Race-test exact-store fixtures unavailable for %',p_shop_domain;
  END IF;

  INSERT INTO henvalt.shopify_recovery_intervention_v2(
    tenant_id,shopify_connection_id,opportunity_id,customer_identity_id,
    step_number,status,scheduled_at
  ) VALUES(v_tenant,v_connection,v_opportunity,v_customer,9,'SUBMITTED',now())
  RETURNING id INTO v_intervention;

  INSERT INTO henvalt.shopify_recovery_send_attempt_v2(
    tenant_id,shopify_connection_id,customer_identity_id,intervention_id,
    provider_account_key,idempotency_key,status
  ) VALUES(v_tenant,v_connection,v_customer,v_intervention,v_provider,
    'race-'||replace(p_shop_domain,'.','-'),'AUTHORIZED')
  RETURNING id INTO v_attempt;

  -- Keep the billing-row lock held long enough for the competing session to block.
  PERFORM pg_catalog.pg_sleep(1);
  RETURN v_attempt;
END;
$race$;

DO $prepare$
DECLARE v_tenant uuid:='00000000-0000-4000-8000-000000000001'; v_total numeric(18,6);
BEGIN
  SELECT COALESCE(sum(amount),0) INTO v_total
  FROM henvalt.shopify_delivery_cost_reservations_v2
  WHERE tenant_id=v_tenant AND status IN ('RESERVED','SETTLED');
  UPDATE henvalt.billing_accounts
     SET usage_cap_amount=v_total+0.01,monthly_email_limit=50
   WHERE tenant_id=v_tenant;
  IF NOT FOUND THEN RAISE EXCEPTION 'Race-test billing account missing'; END IF;
END;
$prepare$;

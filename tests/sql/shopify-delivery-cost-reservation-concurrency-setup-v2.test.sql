-- Disposable-database setup for a mixed checkout-vs-pixel merchant-wide reservation race.
\set ON_ERROR_STOP on
CREATE OR REPLACE FUNCTION henvalt.test_cost_reservation_race_v2(p_shop_domain text)
RETURNS uuid
LANGUAGE plpgsql
AS $race$
DECLARE
  v_tenant uuid:='00000000-0000-4000-8000-000000000001';
  v_connection uuid; v_customer uuid; v_opportunity uuid; v_provider text;
  v_intervention uuid; v_attempt uuid; v_session uuid; v_inbox uuid; v_pixel_candidate uuid;
BEGIN
  IF p_shop_domain NOT IN ('store-a.myshopify.com','store-b.myshopify.com') THEN
    RAISE EXCEPTION 'Unexpected race-test store';
  END IF;
  SELECT id INTO v_connection FROM henvalt.shopify_connections
    WHERE tenant_id=v_tenant AND shop_domain=p_shop_domain;
  SELECT id INTO v_customer FROM henvalt.shopify_customer_identity_v2
    WHERE tenant_id=v_tenant AND shopify_connection_id=v_connection
      AND external_customer_reference='12345';
  SELECT provider_account_key INTO v_provider FROM henvalt.shopify_mailer_provider_registry_v2
    WHERE tenant_id=v_tenant AND status='ACTIVE'
      AND email_unit_cost_amount=0.01 AND email_unit_cost_currency='USD'
    ORDER BY created_at LIMIT 1;
  IF v_connection IS NULL OR v_customer IS NULL OR v_provider IS NULL THEN
    RAISE EXCEPTION 'Race-test exact-store fixtures unavailable for %',p_shop_domain;
  END IF;

  IF p_shop_domain='store-a.myshopify.com' THEN
    SELECT id INTO v_opportunity FROM henvalt.shopify_recovery_opportunity_v2
      WHERE tenant_id=v_tenant AND shopify_connection_id=v_connection
        AND opportunity_type='ABANDONED_CHECKOUT'
      ORDER BY created_at DESC LIMIT 1;
    IF v_opportunity IS NULL THEN RAISE EXCEPTION 'Checkout opportunity missing for Store A'; END IF;
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
  ELSE
    -- Build a real pixel candidate/opportunity lineage in Store B, then exercise
    -- the pixel attempt's own AFTER INSERT reservation trigger.
    INSERT INTO henvalt.shopify_pixel_event_inbox_v2(
      tenant_id,shopify_connection_id,source_event_id,event_type,event_digest,
      occurred_at,analytics_processing_allowed,marketing_allowed,
      client_reference,customer_reference,payload,status,processed_at
    ) VALUES(
      v_tenant,v_connection,'pixel-race-'||replace(p_shop_domain,'.','-'),
      'product_added_to_cart',
      encode(extensions.digest(convert_to('pixel-race:'||p_shop_domain,'UTF8'),'sha256'),'hex'),
      now()-interval '60 minutes',true,false,'race-browser','12345',
      '{"product":{"id":"race-product"}}'::jsonb,'PROCESSED',now()
    ) RETURNING id INTO v_inbox;

    INSERT INTO henvalt.shopify_session_identity_v2(
      tenant_id,shopify_connection_id,session_reference,customer_identity_id,
      first_seen_at,last_seen_at
    ) VALUES(v_tenant,v_connection,'race-session-'||replace(p_shop_domain,'.','-'),
      v_customer,now()-interval '1 hour',now())
    RETURNING id INTO v_session;

    INSERT INTO henvalt.shopify_pixel_recovery_candidate_v2(
      tenant_id,shopify_connection_id,candidate_type,session_identity_id,
      customer_identity_id,source_inbox_event_id,product_key,product_context,
      value_at_risk,currency,last_activity_at,eligible_after,status,idempotency_key
    ) VALUES(v_tenant,v_connection,'ABANDONED_CART',v_session,v_customer,v_inbox,
      'race-product','{"product_id":"race-product"}'::jsonb,12.00,'USD',
      now()-interval '60 minutes',now()-interval '30 minutes','PROMOTED',
      'race-pixel-'||replace(p_shop_domain,'.','-'))
    RETURNING id INTO v_pixel_candidate;

    INSERT INTO henvalt.shopify_recovery_opportunity_v2(
      tenant_id,shopify_connection_id,app_key,candidate_id,checkout_identity_id,
      customer_identity_id,source_delivery_id,pixel_candidate_id,opportunity_type,
      status,value_at_risk,currency,idempotency_key
    )
    SELECT v_tenant,v_connection,sc.app_key,NULL,NULL,v_customer,NULL,
      v_pixel_candidate,'ABANDONED_CART','REVIEW_REQUIRED',12.00,'USD',
      'race-pixel-opportunity-'||replace(p_shop_domain,'.','-')
    FROM henvalt.shopify_connections sc WHERE sc.id=v_connection
    RETURNING id INTO v_opportunity;

    INSERT INTO henvalt.shopify_pixel_send_attempts_v2(
      tenant_id,shopify_connection_id,opportunity_id,pixel_candidate_id,
      customer_identity_id,provider_account_key,idempotency_key,status
    ) VALUES(v_tenant,v_connection,v_opportunity,v_pixel_candidate,v_customer,
      v_provider,'race-pixel-'||replace(p_shop_domain,'.','-'),'AUTHORIZED')
    RETURNING id INTO v_attempt;
  END IF;

  -- Keep the shared billing-account row lock held so the competing store blocks.
  PERFORM pg_catalog.pg_sleep(1);
  RETURN v_attempt;
END;
$race$;

DO $prepare$
DECLARE v_tenant uuid:='00000000-0000-4000-8000-000000000001'; v_total numeric(18,6);
BEGIN
  SELECT COALESCE(sum(amount),0) INTO v_total
  FROM (
    SELECT amount FROM henvalt.shopify_delivery_cost_reservations_v2
      WHERE tenant_id=v_tenant AND status IN ('RESERVED','SETTLED')
    UNION ALL
    SELECT amount FROM henvalt.shopify_pixel_delivery_cost_reservations_v2
      WHERE tenant_id=v_tenant AND status IN ('RESERVED','SETTLED')
  ) reservations;
  UPDATE henvalt.billing_accounts
     SET usage_cap_amount=v_total+0.01,monthly_email_limit=50
   WHERE tenant_id=v_tenant;
  IF NOT FOUND THEN RAISE EXCEPTION 'Race-test billing account missing'; END IF;
END;
$prepare$;

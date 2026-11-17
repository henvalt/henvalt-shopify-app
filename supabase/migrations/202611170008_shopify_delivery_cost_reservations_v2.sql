-- HENVALT merchant-wide provider cost reservations V2.
-- PREPARATION ONLY. Candidate migration; do not apply to production until reviewed.
-- Costs are explicitly configured in the merchant billing currency. No FX or defaults.

BEGIN;

ALTER TABLE henvalt.shopify_mailer_provider_registry_v2
  ADD COLUMN IF NOT EXISTS email_unit_cost_amount numeric(18,6),
  ADD COLUMN IF NOT EXISTS email_unit_cost_currency text;

ALTER TABLE henvalt.shopify_mailer_provider_registry_v2
  DROP CONSTRAINT IF EXISTS shopify_mailer_provider_registry_v2_email_cost_check;
ALTER TABLE henvalt.shopify_mailer_provider_registry_v2
  ADD CONSTRAINT shopify_mailer_provider_registry_v2_email_cost_check
  CHECK (
    (email_unit_cost_amount IS NULL AND email_unit_cost_currency IS NULL)
    OR
    (email_unit_cost_amount IS NOT NULL AND email_unit_cost_amount > 0
      AND email_unit_cost_currency IS NOT NULL
      AND email_unit_cost_currency ~ '^[A-Z]{3}$')
  );

CREATE TABLE IF NOT EXISTS henvalt.shopify_delivery_cost_reservations_v2 (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id uuid NOT NULL,
  shopify_connection_id uuid NOT NULL,
  send_attempt_id uuid NOT NULL UNIQUE,
  provider_account_key text NOT NULL,
  period_start timestamptz NOT NULL,
  amount numeric(18,6) NOT NULL CHECK (amount > 0),
  currency text NOT NULL CHECK (currency ~ '^[A-Z]{3}$'),
  status text NOT NULL DEFAULT 'RESERVED'
    CHECK (status IN ('RESERVED','SETTLED','RELEASED')),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT shopify_delivery_cost_reservations_v2_attempt_fkey
    FOREIGN KEY (send_attempt_id,tenant_id,shopify_connection_id)
    REFERENCES henvalt.shopify_recovery_send_attempt_v2(id,tenant_id,shopify_connection_id)
    ON UPDATE RESTRICT ON DELETE RESTRICT,
  CONSTRAINT shopify_delivery_cost_reservations_v2_provider_fkey
    FOREIGN KEY (provider_account_key,tenant_id)
    REFERENCES henvalt.shopify_mailer_provider_registry_v2(provider_account_key,tenant_id)
    ON UPDATE RESTRICT ON DELETE RESTRICT
);

CREATE INDEX IF NOT EXISTS shopify_delivery_cost_reservations_v2_period_idx
  ON henvalt.shopify_delivery_cost_reservations_v2(tenant_id,period_start)
  WHERE status IN ('RESERVED','SETTLED');

ALTER TABLE henvalt.shopify_delivery_cost_reservations_v2 ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON henvalt.shopify_delivery_cost_reservations_v2
  FROM PUBLIC,anon,authenticated,service_role;

COMMENT ON TABLE henvalt.shopify_delivery_cost_reservations_v2 IS
  'Merchant-wide billing-period provider cost reservations. RESERVED and SETTLED consume cap; AMBIGUOUS sends remain RESERVED until provider reconciliation.';

CREATE OR REPLACE FUNCTION henvalt.reserve_shopify_delivery_cost_v2()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_billing henvalt.billing_accounts%ROWTYPE;
  v_provider henvalt.shopify_mailer_provider_registry_v2%ROWTYPE;
  v_period_start timestamptz;
  v_reserved numeric(18,6);
  v_monthly_count bigint;
BEGIN
  IF NEW.status <> 'AUTHORIZED' THEN
    RAISE EXCEPTION 'delivery cost reservation requires AUTHORIZED send attempt';
  END IF;

  -- Serialize all stores under the same merchant billing account.
  SELECT * INTO v_billing
  FROM henvalt.billing_accounts
  WHERE tenant_id=NEW.tenant_id
  FOR UPDATE;
  IF NOT FOUND OR v_billing.status <> 'ACTIVE'
     OR v_billing.test_mode IS DISTINCT FROM false
     OR v_billing.usage_cap_amount IS NULL OR v_billing.usage_cap_amount <= 0
     OR v_billing.monthly_email_limit IS NULL OR v_billing.monthly_email_limit <= 0
     OR v_billing.currency IS NULL
     OR pg_catalog.upper(pg_catalog.btrim(v_billing.currency::text)) !~ '^[A-Z]{3}$' THEN
    RAISE EXCEPTION 'merchant billing account is not eligible for delivery reservation';
  END IF;

  SELECT * INTO v_provider
  FROM henvalt.shopify_mailer_provider_registry_v2
  WHERE tenant_id=NEW.tenant_id
    AND provider_account_key=NEW.provider_account_key
    AND status='ACTIVE'
  FOR SHARE;
  IF NOT FOUND OR v_provider.email_unit_cost_amount IS NULL
     OR v_provider.email_unit_cost_amount <= 0
     OR v_provider.email_unit_cost_currency IS NULL
     OR v_provider.email_unit_cost_currency !~ '^[A-Z]{3}$'
     OR v_provider.email_unit_cost_currency <>
       pg_catalog.upper(pg_catalog.btrim(v_billing.currency::text)) THEN
    RAISE EXCEPTION 'provider unit cost must be configured in merchant billing currency';
  END IF;

  v_period_start := pg_catalog.date_trunc('month',NEW.created_at);
  SELECT coalesce(sum(r.amount),0) INTO v_reserved
  FROM henvalt.shopify_delivery_cost_reservations_v2 r
  WHERE r.tenant_id=NEW.tenant_id
    AND r.period_start=v_period_start
    AND r.currency=pg_catalog.upper(pg_catalog.btrim(v_billing.currency::text))
    AND r.status IN ('RESERVED','SETTLED');

  IF v_reserved + v_provider.email_unit_cost_amount > v_billing.usage_cap_amount THEN
    RAISE EXCEPTION 'merchant monetary usage cap would be exceeded';
  END IF;

  SELECT count(*) INTO v_monthly_count
  FROM henvalt.shopify_recovery_send_attempt_v2 a
  WHERE a.tenant_id=NEW.tenant_id
    AND a.created_at >= v_period_start
    AND a.created_at < v_period_start + interval '1 month';
  IF v_monthly_count > v_billing.monthly_email_limit THEN
    RAISE EXCEPTION 'merchant monthly email limit would be exceeded';
  END IF;

  INSERT INTO henvalt.shopify_delivery_cost_reservations_v2(
    tenant_id,shopify_connection_id,send_attempt_id,provider_account_key,
    period_start,amount,currency,status
  ) VALUES (
    NEW.tenant_id,NEW.shopify_connection_id,NEW.id,NEW.provider_account_key,
    v_period_start,v_provider.email_unit_cost_amount,
    pg_catalog.upper(pg_catalog.btrim(v_billing.currency::text)),'RESERVED'
  );
  RETURN NEW;
END;
$function$;

CREATE OR REPLACE FUNCTION henvalt.sync_shopify_delivery_cost_reservation_v2()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
BEGIN
  IF NEW.status IS DISTINCT FROM OLD.status THEN
    UPDATE henvalt.shopify_delivery_cost_reservations_v2
    SET status=CASE
      WHEN NEW.status='SUBMITTED' THEN 'SETTLED'
      WHEN NEW.status='FAILED' THEN 'RELEASED'
      WHEN NEW.status='AMBIGUOUS' THEN 'RESERVED'
      ELSE status
    END,
    updated_at=pg_catalog.now()
    WHERE send_attempt_id=NEW.id
      AND tenant_id=NEW.tenant_id
      AND shopify_connection_id=NEW.shopify_connection_id
      AND status IN ('RESERVED','SETTLED');
  END IF;
  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS shopify_delivery_cost_reserve_after_attempt_v2
  ON henvalt.shopify_recovery_send_attempt_v2;
CREATE TRIGGER shopify_delivery_cost_reserve_after_attempt_v2
AFTER INSERT ON henvalt.shopify_recovery_send_attempt_v2
FOR EACH ROW EXECUTE FUNCTION henvalt.reserve_shopify_delivery_cost_v2();

DROP TRIGGER IF EXISTS shopify_delivery_cost_status_sync_v2
  ON henvalt.shopify_recovery_send_attempt_v2;
CREATE TRIGGER shopify_delivery_cost_status_sync_v2
AFTER UPDATE OF status ON henvalt.shopify_recovery_send_attempt_v2
FOR EACH ROW EXECUTE FUNCTION henvalt.sync_shopify_delivery_cost_reservation_v2();

REVOKE ALL ON FUNCTION henvalt.reserve_shopify_delivery_cost_v2()
  FROM PUBLIC,anon,authenticated,service_role;
REVOKE ALL ON FUNCTION henvalt.sync_shopify_delivery_cost_reservation_v2()
  FROM PUBLIC,anon,authenticated,service_role;


-- Replace the migration-018 permanent gate only after the atomic reservation
-- trigger exists. This is a preflight for explicit cost configuration; the
-- consume-permit INSERT performs the authoritative serialized reservation.
CREATE OR REPLACE FUNCTION henvalt.resolve_shopify_delivery_context_v2(p_intervention_id uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $function$
DECLARE v_row record; v_access_token text; v_api_token text; v_fingerprint_secret text;
BEGIN
  IF p_intervention_id IS NULL THEN
    RETURN jsonb_build_object('ready',false,'code','INTERVENTION_REQUIRED');
  END IF;
  SELECT i.id AS intervention_id,i.tenant_id,i.shopify_connection_id,i.customer_identity_id,
    i.status AS intervention_status,opp.status AS opportunity_status,opp.app_key,opp.candidate_id,
    opp.checkout_identity_id,opp.customer_identity_id AS opportunity_customer_id,
    c.state AS candidate_state,c.checkout_token,c.checkout_identity_id AS candidate_checkout_id,
    ch.checkout_status,ch.jurisdiction_country_code,ch.shopify_checkout_token,
    ch.customer_identity_id AS checkout_customer_id,ci.external_customer_reference,
    sc.shop_domain,sc.shopify_shop_id,sc.access_token_secret_ref,sc.access_token_expires_at,
    sc.token_type,sc.reauth_required_at,sc.scopes,sc.active AS connection_active,sc.app_key AS connection_app_key,
    ar.shopify_client_id,ar.lifecycle_status AS app_status,t.status::text AS tenant_status,
    consent.marketing_state,consent.consent_updated_at,pr.provider_account_key,pr.status AS provider_status,
    pr.api_token_secret_ref,pr.recipient_fingerprint_secret_ref,
    pr.email_unit_cost_amount,pr.email_unit_cost_currency,
    sp.id AS sender_profile_id,sp.status AS sender_status,sp.verified_at,
    ba.status AS billing_status,ba.test_mode,ba.henvalt_percentage,ba.usage_cap_amount,
    ba.monthly_email_limit,ba.currency AS billing_currency
  INTO v_row
  FROM henvalt.shopify_recovery_intervention_v2 i
  JOIN henvalt.shopify_recovery_opportunity_v2 opp ON opp.id=i.opportunity_id AND opp.tenant_id=i.tenant_id AND opp.shopify_connection_id=i.shopify_connection_id
  JOIN henvalt.shopify_checkout_recovery_candidate_v2 c ON c.id=opp.candidate_id AND c.tenant_id=i.tenant_id AND c.shopify_connection_id=i.shopify_connection_id
  JOIN henvalt.shopify_checkout_identity_v2 ch ON ch.id=opp.checkout_identity_id AND ch.tenant_id=i.tenant_id AND ch.shopify_connection_id=i.shopify_connection_id
  JOIN henvalt.shopify_customer_identity_v2 ci ON ci.id=i.customer_identity_id AND ci.tenant_id=i.tenant_id AND ci.shopify_connection_id=i.shopify_connection_id
  JOIN henvalt.shopify_connections sc ON sc.id=i.shopify_connection_id AND sc.tenant_id=i.tenant_id
  JOIN henvalt.shopify_app_registry ar ON ar.app_key=opp.app_key
  JOIN henvalt.tenants t ON t.id=i.tenant_id
  JOIN henvalt.shopify_customer_email_consent_v2 consent ON consent.customer_identity_id=i.customer_identity_id AND consent.tenant_id=i.tenant_id AND consent.shopify_connection_id=i.shopify_connection_id
  JOIN henvalt.shopify_mailer_provider_registry_v2 pr ON pr.tenant_id=i.tenant_id
  JOIN henvalt.shopify_sender_profiles_v2 sp ON sp.tenant_id=i.tenant_id AND sp.shopify_connection_id=i.shopify_connection_id AND sp.provider_account_key=pr.provider_account_key
  JOIN henvalt.billing_accounts ba ON ba.tenant_id=i.tenant_id
  WHERE i.id=p_intervention_id AND i.status='READY_FOR_AUTHORIZATION'
  ORDER BY pr.created_at,sp.created_at LIMIT 1;

  IF NOT FOUND THEN RETURN jsonb_build_object('ready',false,'code','DELIVERY_CONTEXT_NOT_FOUND'); END IF;
  IF v_row.opportunity_status<>'CONTACT_RESOLUTION_PENDING' OR v_row.candidate_state<>'READY_FOR_CONTACT_RESOLUTION'
     OR v_row.opportunity_customer_id IS DISTINCT FROM v_row.customer_identity_id
     OR v_row.checkout_customer_id IS DISTINCT FROM v_row.customer_identity_id
     OR v_row.candidate_checkout_id IS DISTINCT FROM v_row.checkout_identity_id
    THEN RETURN jsonb_build_object('ready',false,'code','RECOVERY_CHAIN_NOT_ELIGIBLE'); END IF;
  IF v_row.connection_active IS DISTINCT FROM true OR v_row.app_status<>'active'
     OR v_row.connection_app_key IS DISTINCT FROM v_row.app_key OR v_row.tenant_status<>'ACTIVE'
    THEN RETURN jsonb_build_object('ready',false,'code','APP_STORE_OR_TENANT_INACTIVE'); END IF;
  IF v_row.shop_domain NOT LIKE '%.myshopify.com' OR v_row.token_type <> 'offline_expiring'
     OR v_row.reauth_required_at IS NOT NULL OR coalesce('read_customers'=ANY(v_row.scopes),false) IS NOT TRUE
    THEN RETURN jsonb_build_object('ready',false,'code','SHOPIFY_CUSTOMER_ACCESS_UNAVAILABLE'); END IF;
  IF v_row.checkout_status<>'OPEN' OR v_row.shopify_checkout_token IS DISTINCT FROM v_row.checkout_token
     OR v_row.jurisdiction_country_code IS NULL
     OR v_row.jurisdiction_country_code NOT IN ('GB','US','CA','AU')
    THEN RETURN jsonb_build_object('ready',false,'code','CHECKOUT_OR_JURISDICTION_INELIGIBLE'); END IF;
  IF EXISTS(SELECT 1 FROM henvalt.shopify_order_identity_v2 o WHERE o.tenant_id=v_row.tenant_id AND o.shopify_connection_id=v_row.shopify_connection_id AND o.checkout_token=v_row.checkout_token)
    THEN RETURN jsonb_build_object('ready',false,'code','SAME_STORE_ORDER_EXISTS'); END IF;
  IF v_row.marketing_state<>'SUBSCRIBED' OR v_row.consent_updated_at IS NULL
    THEN RETURN jsonb_build_object('ready',false,'code','CURRENT_EMAIL_CONSENT_REQUIRED'); END IF;
  IF EXISTS(SELECT 1 FROM henvalt.shopify_delivery_suppressions_v2 s WHERE s.tenant_id=v_row.tenant_id AND s.shopify_connection_id=v_row.shopify_connection_id AND s.customer_identity_id=v_row.customer_identity_id AND s.active IS TRUE)
    THEN RETURN jsonb_build_object('ready',false,'code','RECIPIENT_SUPPRESSED'); END IF;
  IF v_row.provider_status<>'ACTIVE' OR v_row.api_token_secret_ref IS NULL OR v_row.recipient_fingerprint_secret_ref IS NULL
     OR v_row.email_unit_cost_amount IS NULL OR v_row.email_unit_cost_amount<=0
     OR v_row.email_unit_cost_currency IS NULL
     OR v_row.email_unit_cost_currency !~ '^[A-Z]{3}

     OR v_row.email_unit_cost_currency <> pg_catalog.upper(pg_catalog.btrim(v_row.billing_currency::text))
     OR v_row.sender_status<>'ACTIVE' OR v_row.verified_at IS NULL
     OR v_row.billing_status<>'ACTIVE' OR v_row.test_mode IS DISTINCT FROM false
     OR v_row.henvalt_percentage IS NULL OR v_row.henvalt_percentage<=0
     OR v_row.usage_cap_amount IS NULL OR v_row.usage_cap_amount<=0
     OR v_row.monthly_email_limit IS NULL OR v_row.monthly_email_limit<=0
    THEN RETURN jsonb_build_object('ready',false,'code','BILLING_PROVIDER_OR_SENDER_NOT_READY'); END IF;
  IF v_row.access_token_expires_at IS NULL OR v_row.access_token_expires_at<=pg_catalog.now()+interval '2 minutes'
    THEN RETURN jsonb_build_object('ready',false,'code','SHOPIFY_TOKEN_REFRESH_REQUIRED','shop_domain',v_row.shop_domain,'shopify_client_id',v_row.shopify_client_id); END IF;

  -- No send authorization is issued here. The one-time permit consume inserts
  -- AUTHORIZED attempt; migration-019 trigger reserves merchant-wide cost
  -- atomically and rolls back the attempt if cap/limit/currency checks fail.
  SELECT ds.decrypted_secret INTO v_access_token FROM vault.decrypted_secrets ds WHERE ds.id=v_row.access_token_secret_ref::uuid;
  SELECT ds.decrypted_secret INTO v_api_token FROM vault.decrypted_secrets ds WHERE ds.name=v_row.api_token_secret_ref OR ds.id::text=v_row.api_token_secret_ref LIMIT 1;
  SELECT ds.decrypted_secret INTO v_fingerprint_secret FROM vault.decrypted_secrets ds WHERE ds.name=v_row.recipient_fingerprint_secret_ref OR ds.id::text=v_row.recipient_fingerprint_secret_ref LIMIT 1;
  IF v_access_token IS NULL OR v_access_token='' OR v_api_token IS NULL OR v_api_token=''
     OR v_fingerprint_secret IS NULL OR length(v_fingerprint_secret)<32
    THEN RETURN jsonb_build_object('ready',false,'code','DELIVERY_SECRET_UNAVAILABLE'); END IF;

  RETURN jsonb_build_object('ready',true,'intervention_id',v_row.intervention_id,'tenant_id',v_row.tenant_id,
    'shopify_connection_id',v_row.shopify_connection_id,'customer_identity_id',v_row.customer_identity_id,
    'external_customer_reference',v_row.external_customer_reference,'shop_domain',v_row.shop_domain,
    'shopify_shop_id',v_row.shopify_shop_id,'shopify_client_id',v_row.shopify_client_id,
    'access_token',v_access_token,'provider_account_key',v_row.provider_account_key,
    'mailer_send_api_token',v_api_token,'recipient_fingerprint_secret',v_fingerprint_secret,
    'sender_profile_id',v_row.sender_profile_id);
END;
$function$;

REVOKE ALL ON FUNCTION henvalt.resolve_shopify_delivery_context_v2(uuid) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION henvalt.resolve_shopify_delivery_context_v2(uuid) TO service_role;

COMMIT;
 OR v_row.token_type<>'offline_expiring'
     OR v_row.reauth_required_at IS NOT NULL OR coalesce('read_customers'=ANY(v_row.scopes),false) IS NOT TRUE
    THEN RETURN jsonb_build_object('ready',false,'code','SHOPIFY_CUSTOMER_ACCESS_UNAVAILABLE'); END IF;
  IF v_row.checkout_status<>'OPEN' OR v_row.shopify_checkout_token IS DISTINCT FROM v_row.checkout_token
     OR v_row.jurisdiction_country_code IS NULL
     OR v_row.jurisdiction_country_code NOT IN ('GB','US','CA','AU')
    THEN RETURN jsonb_build_object('ready',false,'code','CHECKOUT_OR_JURISDICTION_INELIGIBLE'); END IF;
  IF EXISTS(SELECT 1 FROM henvalt.shopify_order_identity_v2 o WHERE o.tenant_id=v_row.tenant_id AND o.shopify_connection_id=v_row.shopify_connection_id AND o.checkout_token=v_row.checkout_token)
    THEN RETURN jsonb_build_object('ready',false,'code','SAME_STORE_ORDER_EXISTS'); END IF;
  IF v_row.marketing_state<>'SUBSCRIBED' OR v_row.consent_updated_at IS NULL
    THEN RETURN jsonb_build_object('ready',false,'code','CURRENT_EMAIL_CONSENT_REQUIRED'); END IF;
  IF EXISTS(SELECT 1 FROM henvalt.shopify_delivery_suppressions_v2 s WHERE s.tenant_id=v_row.tenant_id AND s.shopify_connection_id=v_row.shopify_connection_id AND s.customer_identity_id=v_row.customer_identity_id AND s.active IS TRUE)
    THEN RETURN jsonb_build_object('ready',false,'code','RECIPIENT_SUPPRESSED'); END IF;
  IF v_row.provider_status<>'ACTIVE' OR v_row.api_token_secret_ref IS NULL OR v_row.recipient_fingerprint_secret_ref IS NULL
     OR v_row.email_unit_cost_amount IS NULL OR v_row.email_unit_cost_amount<=0
     OR v_row.email_unit_cost_currency IS NULL
     OR v_row.email_unit_cost_currency !~ '^[A-Z]{3}

     OR v_row.email_unit_cost_currency <> pg_catalog.upper(pg_catalog.btrim(v_row.billing_currency::text))
     OR v_row.sender_status<>'ACTIVE' OR v_row.verified_at IS NULL
     OR v_row.billing_status<>'ACTIVE' OR v_row.test_mode IS DISTINCT FROM false
     OR v_row.henvalt_percentage IS NULL OR v_row.henvalt_percentage<=0
     OR v_row.usage_cap_amount IS NULL OR v_row.usage_cap_amount<=0
     OR v_row.monthly_email_limit IS NULL OR v_row.monthly_email_limit<=0
    THEN RETURN jsonb_build_object('ready',false,'code','BILLING_PROVIDER_OR_SENDER_NOT_READY'); END IF;
  IF v_row.access_token_expires_at IS NULL OR v_row.access_token_expires_at<=pg_catalog.now()+interval '2 minutes'
    THEN RETURN jsonb_build_object('ready',false,'code','SHOPIFY_TOKEN_REFRESH_REQUIRED','shop_domain',v_row.shop_domain,'shopify_client_id',v_row.shopify_client_id); END IF;

  -- No send authorization is issued here. The one-time permit consume inserts
  -- AUTHORIZED attempt; migration-019 trigger reserves merchant-wide cost
  -- atomically and rolls back the attempt if cap/limit/currency checks fail.
  SELECT ds.decrypted_secret INTO v_access_token FROM vault.decrypted_secrets ds WHERE ds.id=v_row.access_token_secret_ref::uuid;
  SELECT ds.decrypted_secret INTO v_api_token FROM vault.decrypted_secrets ds WHERE ds.name=v_row.api_token_secret_ref OR ds.id::text=v_row.api_token_secret_ref LIMIT 1;
  SELECT ds.decrypted_secret INTO v_fingerprint_secret FROM vault.decrypted_secrets ds WHERE ds.name=v_row.recipient_fingerprint_secret_ref OR ds.id::text=v_row.recipient_fingerprint_secret_ref LIMIT 1;
  IF v_access_token IS NULL OR v_access_token='' OR v_api_token IS NULL OR v_api_token=''
     OR v_fingerprint_secret IS NULL OR length(v_fingerprint_secret)<32
    THEN RETURN jsonb_build_object('ready',false,'code','DELIVERY_SECRET_UNAVAILABLE'); END IF;

  RETURN jsonb_build_object('ready',true,'intervention_id',v_row.intervention_id,'tenant_id',v_row.tenant_id,
    'shopify_connection_id',v_row.shopify_connection_id,'customer_identity_id',v_row.customer_identity_id,
    'external_customer_reference',v_row.external_customer_reference,'shop_domain',v_row.shop_domain,
    'shopify_shop_id',v_row.shopify_shop_id,'shopify_client_id',v_row.shopify_client_id,
    'access_token',v_access_token,'provider_account_key',v_row.provider_account_key,
    'mailer_send_api_token',v_api_token,'recipient_fingerprint_secret',v_fingerprint_secret,
    'sender_profile_id',v_row.sender_profile_id);
END;
$function$;

REVOKE ALL ON FUNCTION henvalt.resolve_shopify_delivery_context_v2(uuid) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION henvalt.resolve_shopify_delivery_context_v2(uuid) TO service_role;

COMMIT;

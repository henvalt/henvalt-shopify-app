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

COMMIT;

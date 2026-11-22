\set ON_ERROR_STOP on

CREATE SCHEMA IF NOT EXISTS extensions;
CREATE EXTENSION IF NOT EXISTS pgcrypto WITH SCHEMA extensions;

DO $bootstrap$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'anon') THEN
    CREATE ROLE anon NOLOGIN;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'authenticated') THEN
    CREATE ROLE authenticated NOLOGIN;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'service_role') THEN
    CREATE ROLE service_role NOLOGIN;
  END IF;
END
$bootstrap$;

CREATE SCHEMA henvalt;
CREATE TYPE henvalt.delivery_state AS ENUM ('PENDING', 'UNKNOWN', 'ACCEPTED', 'DELIVERED', 'FAILED');
CREATE TABLE henvalt.delivery_requests (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id uuid,
  message_reference uuid,
  status henvalt.delivery_state NOT NULL,
  provider_claimed_at timestamptz
);

CREATE TABLE henvalt.messages (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id uuid NOT NULL,
  metadata jsonb NOT NULL DEFAULT '{}'::jsonb
);
ALTER TABLE henvalt.messages
  ADD COLUMN intervention_id uuid,
  ADD COLUMN recipient text,
  ADD COLUMN subject text,
  ADD COLUMN body text;

CREATE TYPE henvalt.event_class AS ENUM ('RECOVERABLE', 'CONVERSION', 'ADJUSTMENT', 'OTHER');
CREATE TYPE henvalt.opportunity_type AS ENUM ('ABANDONED_CART', 'ABANDONED_CHECKOUT', 'PAYMENT_FAILURE', 'PAYMENT_DECLINED', 'BROWSE_ABANDONMENT');
CREATE TYPE henvalt.channel_type AS ENUM ('EMAIL', 'WHATSAPP', 'SMS', 'RCS', 'PUSH', 'OTHER');

CREATE TABLE henvalt.tenants (
  id uuid PRIMARY KEY,
  status text NOT NULL,
  default_currency character(3) NOT NULL DEFAULT 'USD'
);
ALTER TABLE henvalt.tenants ADD COLUMN settings jsonb NOT NULL DEFAULT '{}'::jsonb;

CREATE TYPE henvalt.job_status AS ENUM ('QUEUED', 'CLAIMED', 'RUNNING', 'RETRY_WAIT', 'SUCCEEDED', 'DEAD_LETTER');

CREATE TABLE henvalt.webhook_events (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id uuid NOT NULL REFERENCES henvalt.tenants(id) ON DELETE CASCADE,
  source text NOT NULL DEFAULT 'shopify',
  source_event_id text NOT NULL,
  topic text NOT NULL,
  idempotency_key text NOT NULL,
  payload jsonb NOT NULL,
  received_at timestamptz NOT NULL DEFAULT now(),
  processed_at timestamptz,
  processing_status text NOT NULL DEFAULT 'RECEIVED',
  metadata jsonb NOT NULL DEFAULT '{}'::jsonb,
  UNIQUE (tenant_id, idempotency_key),
  UNIQUE (tenant_id, source, source_event_id)
);

CREATE OR REPLACE FUNCTION henvalt.mark_webhook_processed(p_webhook_id uuid)
RETURNS boolean LANGUAGE plpgsql AS $function$
DECLARE v_updated integer;
BEGIN
  UPDATE henvalt.webhook_events
     SET processing_status='PROCESSED', processed_at=now()
   WHERE id=p_webhook_id AND processing_status <> 'PROCESSED';
  GET DIAGNOSTICS v_updated = ROW_COUNT;
  RETURN v_updated = 1;
END;
$function$;

CREATE OR REPLACE FUNCTION henvalt.mark_webhook_failed(p_webhook_id uuid,p_error text)
RETURNS boolean LANGUAGE plpgsql AS $function$
DECLARE v_updated integer;
BEGIN
  UPDATE henvalt.webhook_events
     SET processing_status='FAILED', processed_at=now(),
         metadata=COALESCE(metadata,'{}'::jsonb)||jsonb_build_object('processing_error',p_error)
   WHERE id=p_webhook_id;
  GET DIAGNOSTICS v_updated = ROW_COUNT;
  RETURN v_updated = 1;
END;
$function$;

CREATE TABLE henvalt.background_jobs (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id uuid REFERENCES henvalt.tenants(id) ON DELETE CASCADE,
  job_type text NOT NULL,
  payload jsonb NOT NULL DEFAULT '{}'::jsonb,
  status henvalt.job_status NOT NULL DEFAULT 'QUEUED',
  priority integer NOT NULL DEFAULT 100,
  attempts integer NOT NULL DEFAULT 0 CHECK (attempts >= 0),
  max_attempts integer NOT NULL DEFAULT 5 CHECK (max_attempts > 0),
  run_at timestamptz NOT NULL DEFAULT now(),
  next_run_at timestamptz,
  locked_at timestamptz,
  locked_by text,
  last_error text,
  completed_at timestamptz,
  correlation_id uuid,
  idempotency_key text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (tenant_id, idempotency_key)
);

CREATE OR REPLACE FUNCTION henvalt.claim_next_job(
  p_worker_id text,
  p_job_types text[] DEFAULT NULL::text[]
)
RETURNS SETOF henvalt.background_jobs
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = 'henvalt', 'public'
AS $function$
BEGIN
  RETURN QUERY
  WITH candidate AS (
    SELECT id
      FROM henvalt.background_jobs
     WHERE status IN ('QUEUED', 'RETRY_WAIT')
       AND run_at <= now()
       AND (next_run_at IS NULL OR next_run_at <= now())
       AND attempts < max_attempts
       AND (p_job_types IS NULL OR job_type = ANY(p_job_types))
     ORDER BY priority ASC, created_at ASC
     FOR UPDATE SKIP LOCKED
     LIMIT 1
  )
  UPDATE henvalt.background_jobs j
     SET status = 'CLAIMED',
         attempts = attempts + 1,
         locked_at = now(),
         locked_by = p_worker_id,
         updated_at = now()
    FROM candidate c
   WHERE j.id = c.id
  RETURNING j.*;
END;
$function$;

CREATE OR REPLACE FUNCTION henvalt.ingest_raw_webhook_v2(
  p_tenant_id uuid,
  p_source text,
  p_source_event_id text,
  p_topic text,
  p_idempotency_key text,
  p_payload jsonb,
  p_metadata jsonb DEFAULT '{}'::jsonb
)
RETURNS TABLE(webhook_id uuid, is_duplicate boolean, should_process boolean, processing_status text)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_row henvalt.webhook_events%ROWTYPE;
BEGIN
  SELECT * INTO v_row
    FROM henvalt.webhook_events
   WHERE tenant_id = p_tenant_id
     AND source = p_source
     AND source_event_id = p_source_event_id
   FOR UPDATE;

  IF FOUND THEN
    IF v_row.processing_status = 'PROCESSED' THEN
      RETURN QUERY SELECT v_row.id, true, false, v_row.processing_status;
      RETURN;
    END IF;
    IF v_row.processing_status = 'PROCESSING' THEN
      RETURN QUERY SELECT v_row.id, true, false, v_row.processing_status;
      RETURN;
    END IF;
    UPDATE henvalt.webhook_events
       SET processing_status = 'PROCESSING', processed_at = NULL
     WHERE id = v_row.id
     RETURNING * INTO v_row;
    RETURN QUERY SELECT v_row.id, true, true, v_row.processing_status;
    RETURN;
  END IF;

  INSERT INTO henvalt.webhook_events (
    tenant_id, source, source_event_id, topic, idempotency_key, payload, metadata, processing_status
  ) VALUES (
    p_tenant_id, p_source, p_source_event_id, p_topic, p_idempotency_key, p_payload,
    COALESCE(p_metadata, '{}'::jsonb), 'PROCESSING'
  ) RETURNING * INTO v_row;

  RETURN QUERY SELECT v_row.id, false, true, v_row.processing_status;
END;
$function$;

CREATE TABLE henvalt.shopify_connections (
  id uuid PRIMARY KEY,
  tenant_id uuid NOT NULL,
  active boolean NOT NULL,
  shop_domain text NOT NULL
);



CREATE SCHEMA auth;
CREATE FUNCTION auth.jwt()
RETURNS jsonb
LANGUAGE sql
STABLE
AS $function$
  SELECT jsonb_build_object('role', 'service_role');
$function$;

CREATE SCHEMA vault;
CREATE TABLE vault.decrypted_secrets (
  id uuid PRIMARY KEY,
  name text NOT NULL,
  decrypted_secret text NOT NULL
);

CREATE SEQUENCE henvalt.mailersend_secret_read_counter;

CREATE OR REPLACE FUNCTION henvalt.get_mailersend_token_for_delivery(
  p_tenant_id uuid,
  p_delivery_request_id uuid
)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, henvalt, vault, pg_temp
AS $function$
DECLARE
  v_claimed_id uuid;
  v_token text;
BEGIN
  UPDATE henvalt.delivery_requests
     SET provider_claimed_at = clock_timestamp()
   WHERE id = p_delivery_request_id
     AND status = 'UNKNOWN'
     AND provider_claimed_at IS NULL
  RETURNING id INTO v_claimed_id;

  IF v_claimed_id IS NULL THEN
    RAISE EXCEPTION 'DELIVERY_PROVIDER_ATTEMPT_ALREADY_CLAIMED_OR_UNAUTHORIZED'
      USING ERRCODE = '42501';
  END IF;

  PERFORM nextval('henvalt.mailersend_secret_read_counter');
  SELECT ds.decrypted_secret INTO v_token
    FROM vault.decrypted_secrets ds
   WHERE ds.name = 'synthetic-mailersend-token'
   LIMIT 1;
  RETURN v_token;
END;
$function$;

CREATE OR REPLACE FUNCTION henvalt.verify_shopify_webhook_hmac(p_hmac text, p_raw_body_base64 text)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $function$
  SELECT COALESCE(p_hmac = 'valid-test-hmac', false)
     AND COALESCE(NULLIF(p_raw_body_base64, ''), '') <> ''
     AND EXISTS (
       SELECT 1 FROM vault.decrypted_secrets
        WHERE name = 'henvalt_shopify_app_secret'
          AND decrypted_secret <> ''
     );
$function$;

CREATE OR REPLACE FUNCTION henvalt.resolve_shopify_tenant(p_shop_domain text)
RETURNS uuid
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $function$
  SELECT sc.tenant_id
    FROM henvalt.shopify_connections sc
    JOIN henvalt.tenants t ON t.id = sc.tenant_id
   WHERE lower(sc.shop_domain) = lower(p_shop_domain)
     AND sc.active IS TRUE
     AND t.status = 'ACTIVE'
   LIMIT 1;
$function$;

ALTER TABLE henvalt.shopify_connections
  ADD COLUMN token_type text,
  ADD COLUMN refresh_token_secret_ref text,
  ADD COLUMN access_token_expires_at timestamptz,
  ADD COLUMN refresh_token_expires_at timestamptz,
  ADD COLUMN token_refresh_lease_until timestamptz,
  ADD COLUMN token_refresh_started_at timestamptz,
  ADD COLUMN token_refresh_last_error text,
  ADD COLUMN reauth_required_at timestamptz,
  ADD COLUMN updated_at timestamptz NOT NULL DEFAULT now();

CREATE TABLE henvalt.opportunities (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id uuid NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  opportunity_type text NOT NULL,
  status text NOT NULL,
  value_at_risk numeric,
  currency character(3)
);

CREATE TABLE henvalt.recovery_interventions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id uuid NOT NULL,
  opportunity_id uuid NOT NULL,
  status text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  sent_at timestamptz,
  delivered_at timestamptz
);

CREATE TABLE henvalt.order_attributions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id uuid NOT NULL,
  order_id uuid NOT NULL,
  opportunity_id uuid,
  attribution_confidence text NOT NULL,
  attributed_value numeric,
  evaluated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE henvalt.revenue_ledger (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id uuid NOT NULL,
  order_id uuid,
  opportunity_id uuid,
  entry_type text NOT NULL,
  amount numeric NOT NULL,
  currency character(3) NOT NULL,
  billable boolean NOT NULL,
  attribution_confidence text,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE henvalt.pixel_keys (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id uuid NOT NULL,
  shopify_connection_id uuid NOT NULL,
  key_digest text NOT NULL,
  active boolean NOT NULL,
  revoked_at timestamptz,
  allowed_origins text[] NOT NULL
);

CREATE TABLE henvalt.pixel_rate_limits (
  key_digest text PRIMARY KEY,
  bucket_start timestamptz NOT NULL,
  request_count integer NOT NULL
);

CREATE TABLE henvalt.canonical_events (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id uuid NOT NULL,
  webhook_event_id uuid,
  event_type text NOT NULL,
  event_class henvalt.event_class NOT NULL,
  source text NOT NULL,
  source_event_id text NOT NULL,
  customer_reference text,
  email text,
  anonymous_reference text,
  session_reference text,
  occurred_at timestamptz NOT NULL,
  value_at_risk numeric,
  currency character,
  payload jsonb NOT NULL,
  metadata jsonb NOT NULL,
  idempotency_key text NOT NULL,
  correlation_id uuid,
  UNIQUE (tenant_id, idempotency_key)
);

CREATE TABLE henvalt.customers (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id uuid NOT NULL,
  shopify_customer_id text NOT NULL,
  email text,
  email_consent boolean,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE henvalt.checkouts (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id uuid NOT NULL,
  shopify_checkout_id text,
  session_reference text,
  created_at timestamptz NOT NULL,
  updated_at timestamptz NOT NULL,
  metadata jsonb NOT NULL DEFAULT '{}'::jsonb
);

CREATE TABLE henvalt.session_aliases (
  tenant_id uuid NOT NULL,
  alias_reference text NOT NULL,
  session_reference text NOT NULL
);

CREATE OR REPLACE FUNCTION henvalt.upsert_canonical_event(
  p_tenant_id uuid,
  p_webhook_event_id uuid,
  p_event_type text,
  p_event_class henvalt.event_class,
  p_source text,
  p_source_event_id text,
  p_customer_reference text,
  p_email text,
  p_anonymous_reference text,
  p_session_reference text,
  p_occurred_at timestamptz,
  p_value_at_risk numeric,
  p_currency character,
  p_payload jsonb,
  p_metadata jsonb,
  p_idempotency_key text,
  p_correlation_id uuid DEFAULT NULL
)
RETURNS TABLE(event_id uuid, is_duplicate boolean)
LANGUAGE plpgsql
AS $function$
BEGIN
  SELECT e.id INTO event_id
  FROM henvalt.canonical_events e
  WHERE e.tenant_id = p_tenant_id
    AND e.idempotency_key = p_idempotency_key;

  IF event_id IS NOT NULL THEN
    is_duplicate := true;
    RETURN NEXT;
    RETURN;
  END IF;

  INSERT INTO henvalt.canonical_events (
    tenant_id, webhook_event_id, event_type, event_class, source,
    source_event_id, customer_reference, email, anonymous_reference,
    session_reference, occurred_at, value_at_risk, currency, payload,
    metadata, idempotency_key, correlation_id
  ) VALUES (
    p_tenant_id, p_webhook_event_id, p_event_type, p_event_class, p_source,
    p_source_event_id, p_customer_reference, p_email, p_anonymous_reference,
    p_session_reference, p_occurred_at, p_value_at_risk, p_currency, p_payload,
    p_metadata, p_idempotency_key, p_correlation_id
  )
  RETURNING id INTO event_id;

  is_duplicate := false;
  RETURN NEXT;
END;
$function$;

CREATE OR REPLACE FUNCTION henvalt.resolve_identity(p_event_id uuid)
RETURNS void LANGUAGE plpgsql AS $function$
BEGIN
  RETURN;
END;
$function$;

CREATE OR REPLACE FUNCTION henvalt.bind_session_alias(
  p_tenant_id uuid, p_alias_reference text, p_session_reference text
)
RETURNS void LANGUAGE plpgsql AS $function$
BEGIN
  RETURN;
END;
$function$;

-- Test-only stubs for the remaining legacy Shopify ingest mutation RPCs.
-- The fenced wrappers must reject stale leases before any stub is invoked.
CREATE TYPE henvalt.opportunity_status AS ENUM ('DETECTED','ELIGIBLE','INELIGIBLE','SUPPRESSED','EXPIRED','RECOVERED','CLOSED');
CREATE TABLE henvalt.replay_fence_test_calls (
  id bigserial PRIMARY KEY,
  function_name text NOT NULL
);

CREATE OR REPLACE FUNCTION henvalt.apply_eligibility(
  p_opportunity_id uuid, p_status henvalt.opportunity_status
) RETURNS boolean LANGUAGE plpgsql AS $function$
BEGIN
  INSERT INTO henvalt.replay_fence_test_calls(function_name) VALUES ('apply_eligibility');
  RETURN true;
END;
$function$;

CREATE OR REPLACE FUNCTION henvalt.create_recovery_sequence(
  p_opportunity_id uuid
) RETURNS uuid LANGUAGE plpgsql AS $function$
BEGIN
  INSERT INTO henvalt.replay_fence_test_calls(function_name) VALUES ('create_recovery_sequence');
  RETURN 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'::uuid;
END;
$function$;

CREATE OR REPLACE FUNCTION henvalt.post_recovery_to_ledger_and_measure_billing(
  p_attribution_id uuid
) RETURNS jsonb LANGUAGE plpgsql AS $function$
BEGIN
  INSERT INTO henvalt.replay_fence_test_calls(function_name) VALUES ('post_recovery_to_ledger_and_measure_billing');
  RETURN '{"ledger_entry_id":"bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb","billing_measured":true}'::jsonb;
END;
$function$;

CREATE OR REPLACE FUNCTION henvalt.defer_payment_webhook_reconciliation(
  p_webhook_id uuid, p_error text DEFAULT 'payment_order_not_projected_or_not_linkable'
) RETURNS boolean LANGUAGE plpgsql AS $function$
BEGIN
  INSERT INTO henvalt.replay_fence_test_calls(function_name) VALUES ('defer_payment_webhook_reconciliation');
  RETURN true;
END;
$function$;



-- Delivery-envelope binding fixture shape.
ALTER TABLE henvalt.delivery_requests
  ADD COLUMN recipient_reference text,
  ADD COLUMN channel henvalt.channel_type,
  ADD COLUMN provider text,
  ADD COLUMN delivery_mode text,
  ADD COLUMN intervention_id uuid,
  ADD COLUMN recovery_id uuid,
  ADD COLUMN opportunity_id uuid,
  ADD COLUMN updated_at timestamptz NOT NULL DEFAULT now();

CREATE TABLE henvalt.provider_configs (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id uuid NOT NULL,
  channel henvalt.channel_type NOT NULL,
  provider text NOT NULL,
  active boolean NOT NULL DEFAULT true,
  configuration jsonb NOT NULL DEFAULT '{}'::jsonb
);

CREATE TABLE henvalt.sending_identities (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id uuid NOT NULL,
  channel henvalt.channel_type NOT NULL,
  delivery_mode text NOT NULL,
  provider text NOT NULL,
  sender_reference text NOT NULL,
  provider_config_id uuid NOT NULL,
  active boolean NOT NULL DEFAULT true,
  metadata jsonb NOT NULL DEFAULT '{}'::jsonb,
  updated_at timestamptz NOT NULL DEFAULT now(),
  created_at timestamptz NOT NULL DEFAULT now()
);

-- Minimal relational shape required by the replay object-tenant graph guard.
-- Keep this disposable bootstrap aligned with the production relationship names.
ALTER TABLE henvalt.checkouts
  ADD COLUMN IF NOT EXISTS id uuid NOT NULL DEFAULT gen_random_uuid(),
  ADD COLUMN IF NOT EXISTS customer_id uuid;
CREATE UNIQUE INDEX IF NOT EXISTS checkouts_replay_test_id_uidx ON henvalt.checkouts(id);

ALTER TABLE henvalt.opportunities
  ADD COLUMN IF NOT EXISTS customer_id uuid,
  ADD COLUMN IF NOT EXISTS checkout_id uuid,
  ADD COLUMN IF NOT EXISTS source_event_id uuid;

ALTER TABLE henvalt.recovery_interventions
  ADD COLUMN IF NOT EXISTS sequence_id uuid;

ALTER TABLE henvalt.order_attributions
  ADD COLUMN IF NOT EXISTS recovery_id uuid,
  ADD COLUMN IF NOT EXISTS matched_intervention_id uuid;

CREATE TABLE IF NOT EXISTS henvalt.orders (
  id uuid PRIMARY KEY,
  tenant_id uuid NOT NULL,
  customer_id uuid,
  checkout_id uuid
);

CREATE TABLE IF NOT EXISTS henvalt.recovery_sequences (
  id uuid PRIMARY KEY,
  tenant_id uuid NOT NULL,
  opportunity_id uuid NOT NULL
);

-- Additional relationships rechecked immediately before provider egress.
ALTER TABLE henvalt.opportunities
  ADD COLUMN IF NOT EXISTS customer_id uuid,
  ADD COLUMN IF NOT EXISTS checkout_id uuid,
  ADD COLUMN IF NOT EXISTS metadata jsonb NOT NULL DEFAULT '{}'::jsonb;
ALTER TABLE henvalt.recovery_sequences
  ADD COLUMN IF NOT EXISTS status text NOT NULL DEFAULT 'SCHEDULED';
ALTER TABLE henvalt.orders
  ADD COLUMN IF NOT EXISTS financial_status text,
  ADD COLUMN IF NOT EXISTS cancelled_at timestamptz,
  ADD COLUMN IF NOT EXISTS ordered_at timestamptz;
CREATE TABLE henvalt.email_suppressions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id uuid NOT NULL,
  customer_id uuid,
  email_normalized text NOT NULL,
  active boolean NOT NULL DEFAULT true
);

CREATE OR REPLACE FUNCTION henvalt.render_sender_identity_footer(p_tenant_id uuid, p_html text)
RETURNS text LANGUAGE sql IMMUTABLE AS $function$ SELECT p_html $function$;
CREATE OR REPLACE FUNCTION henvalt.render_email_plain_text(p_html text)
RETURNS text LANGUAGE sql IMMUTABLE AS $function$ SELECT p_html $function$;

CREATE TABLE henvalt.customer_conversations (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id uuid NOT NULL,
  delivery_request_id uuid NOT NULL,
  customer_id uuid,
  opportunity_id uuid,
  recovery_id uuid,
  intervention_id uuid,
  reply_token_hash text NOT NULL,
  status text NOT NULL DEFAULT 'OPEN',
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (tenant_id, delivery_request_id)
);

CREATE OR REPLACE FUNCTION henvalt.evaluate_opportunity_communication_eligibility(
  p_tenant_id uuid, p_opportunity_id uuid
) RETURNS jsonb LANGUAGE sql STABLE AS $function$
  SELECT jsonb_build_object('allowed', true, 'decision', 'ALLOW')
$function$;

CREATE OR REPLACE FUNCTION henvalt.browse_opportunity_advanced(
  p_tenant_id uuid, p_session_reference text, p_source_event_id uuid,
  p_fallback_at timestamptz DEFAULT NULL
) RETURNS boolean LANGUAGE sql STABLE AS $function$
  SELECT false
$function$;

-- Minimal revenue-attribution schema for the confirmed-ledger promotion acceptance.
CREATE TYPE henvalt.attribution_confidence AS ENUM ('UNATTRIBUTED', 'POSSIBLE', 'PROBABLE', 'CONFIRMED');
ALTER TABLE henvalt.order_attributions
  ADD COLUMN IF NOT EXISTS recovery_id uuid,
  ADD COLUMN IF NOT EXISTS matched_intervention_id uuid,
  ADD COLUMN IF NOT EXISTS attribution_method text,
  ADD COLUMN IF NOT EXISTS tracking_token_matched boolean NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS checkout_matched boolean NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS cart_matched boolean NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS customer_matched boolean NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS metadata jsonb NOT NULL DEFAULT '{}'::jsonb;

ALTER TABLE henvalt.orders
  ADD COLUMN IF NOT EXISTS order_number text,
  ADD COLUMN IF NOT EXISTS fulfillment_status text,
  ADD COLUMN IF NOT EXISTS tracking_token text,
  ADD COLUMN IF NOT EXISTS updated_at timestamptz NOT NULL DEFAULT now(),
  ADD COLUMN IF NOT EXISTS shopify_order_id text,
  ADD COLUMN IF NOT EXISTS metadata jsonb NOT NULL DEFAULT '{}'::jsonb,
  ADD COLUMN IF NOT EXISTS total_value numeric(18,2),
  ADD COLUMN IF NOT EXISTS currency character(3),
  ADD COLUMN IF NOT EXISTS financial_status text,
  ADD COLUMN IF NOT EXISTS cancelled_at timestamptz,
  ADD COLUMN IF NOT EXISTS ordered_at timestamptz;

ALTER TABLE henvalt.revenue_ledger
  ADD COLUMN IF NOT EXISTS recovery_id uuid,
  ADD COLUMN IF NOT EXISTS attribution_id uuid,
  ADD COLUMN IF NOT EXISTS billing_status text NOT NULL DEFAULT 'PENDING',
  ADD COLUMN IF NOT EXISTS metadata jsonb NOT NULL DEFAULT '{}'::jsonb;
CREATE TYPE henvalt.ledger_entry_type AS ENUM ('RECOVERY', 'ADJUSTMENT');
CREATE TYPE henvalt.billing_status AS ENUM ('PENDING', 'MEASURED', 'BILLED', 'VOIDED');
ALTER TABLE henvalt.revenue_ledger ALTER COLUMN billing_status DROP DEFAULT;
ALTER TABLE henvalt.revenue_ledger
  ALTER COLUMN attribution_confidence TYPE henvalt.attribution_confidence
    USING NULLIF(attribution_confidence, '')::henvalt.attribution_confidence,
  ALTER COLUMN entry_type TYPE henvalt.ledger_entry_type
    USING entry_type::henvalt.ledger_entry_type,
  ALTER COLUMN billing_status TYPE henvalt.billing_status
    USING billing_status::henvalt.billing_status;
ALTER TABLE henvalt.revenue_ledger
  ALTER COLUMN billing_status SET DEFAULT 'PENDING'::henvalt.billing_status;
CREATE UNIQUE INDEX IF NOT EXISTS revenue_ledger_adjustment_source_event_uidx
  ON henvalt.revenue_ledger(tenant_id, (metadata->>'source_event_id'))
  WHERE entry_type = 'ADJUSTMENT' AND metadata ? 'source_event_id';
CREATE UNIQUE INDEX IF NOT EXISTS orders_tenant_shopify_order_id_uidx
  ON henvalt.orders(tenant_id,shopify_order_id) WHERE shopify_order_id IS NOT NULL;
CREATE UNIQUE INDEX ux_revenue_ledger_one_recovery_per_order
  ON henvalt.revenue_ledger(tenant_id, order_id)
  WHERE entry_type = 'RECOVERY';


-- Billing fixtures used by the refund-credit acceptance suite.
CREATE TABLE henvalt.billing_accounts (
  tenant_id uuid PRIMARY KEY REFERENCES henvalt.tenants(id),
  provider text NOT NULL DEFAULT 'SHOPIFY',
  plan_key text NOT NULL,
  recurring_amount numeric NOT NULL,
  henvalt_percentage numeric NOT NULL,
  usage_cap_amount numeric NOT NULL,
  currency character(3) NOT NULL DEFAULT 'USD',
  provider_subscription_id text,
  usage_line_item_id text,
  status text NOT NULL DEFAULT 'PENDING',
  test_mode boolean NOT NULL DEFAULT false,
  activated_at timestamptz,
  cancelled_at timestamptz,
  monthly_email_limit integer NOT NULL DEFAULT 2000,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE henvalt.billing_measurements (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id uuid NOT NULL REFERENCES henvalt.tenants(id),
  billing_period_id uuid NOT NULL,
  ledger_entry_id uuid,
  recovered_revenue numeric(18,2) NOT NULL,
  henvalt_percentage numeric(8,4) NOT NULL,
  henvalt_fee numeric(18,4) NOT NULL,
  currency character(3) NOT NULL,
  status henvalt.billing_status NOT NULL DEFAULT 'MEASURED',
  paddle_transaction_reference text,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE henvalt.billing_usage_charges (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id uuid NOT NULL REFERENCES henvalt.tenants(id),
  billing_measurement_id uuid NOT NULL UNIQUE REFERENCES henvalt.billing_measurements(id),
  provider text NOT NULL DEFAULT 'SHOPIFY',
  idempotency_key text NOT NULL,
  amount numeric(18,4) NOT NULL,
  currency character(3) NOT NULL,
  status text NOT NULL DEFAULT 'PENDING',
  provider_usage_record_id text,
  error_code text,
  error_message text,
  attempted_at timestamptz,
  submitted_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  attempt_count integer NOT NULL DEFAULT 0,
  UNIQUE (tenant_id,idempotency_key)
);

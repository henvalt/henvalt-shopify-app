\set ON_ERROR_STOP on

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
  status henvalt.delivery_state NOT NULL,
  provider_claimed_at timestamptz
);

CREATE TYPE henvalt.event_class AS ENUM ('OTHER');

CREATE TABLE henvalt.tenants (
  id uuid PRIMARY KEY,
  status text NOT NULL
);

CREATE TABLE henvalt.shopify_connections (
  id uuid PRIMARY KEY,
  tenant_id uuid NOT NULL,
  active boolean NOT NULL,
  shop_domain text NOT NULL
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
  email_consent boolean
);

CREATE TABLE henvalt.checkouts (
  tenant_id uuid NOT NULL,
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
RETURNS void LANGUAGE sql AS $function$
  SELECT;
$function$;

CREATE OR REPLACE FUNCTION henvalt.bind_session_alias(
  p_tenant_id uuid, p_alias_reference text, p_session_reference text
)
RETURNS void LANGUAGE sql AS $function$
  SELECT;
$function$;

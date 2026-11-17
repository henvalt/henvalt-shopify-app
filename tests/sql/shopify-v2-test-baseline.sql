-- Disposable PostgreSQL fixture for candidate Shopify migrations 001-006.
-- This is intentionally minimal and contains synthetic identities only.
CREATE ROLE anon NOLOGIN;
CREATE ROLE authenticated NOLOGIN;
CREATE ROLE service_role NOLOGIN;

CREATE SCHEMA henvalt;
CREATE SCHEMA vault;
CREATE SCHEMA extensions;
CREATE EXTENSION pgcrypto WITH SCHEMA extensions;

CREATE TABLE henvalt.shopify_connections (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id uuid NOT NULL,
  shop_domain text NOT NULL UNIQUE,
  shopify_shop_id text,
  active boolean NOT NULL DEFAULT true,
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE henvalt.shopify_oauth_states (
  state_hash text PRIMARY KEY,
  shop_domain text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  expires_at timestamptz NOT NULL,
  consumed_at timestamptz,
  correlation_id uuid NOT NULL DEFAULT gen_random_uuid(),
  initiated_by_user_id uuid
);

CREATE TABLE vault.secrets (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name text NOT NULL UNIQUE,
  secret text NOT NULL
);
CREATE VIEW vault.decrypted_secrets AS
SELECT id, name, secret AS decrypted_secret
FROM vault.secrets;

CREATE TABLE henvalt.tenants (
  id uuid PRIMARY KEY,
  status text NOT NULL DEFAULT 'ACTIVE'
);

CREATE TABLE henvalt.billing_accounts (
  tenant_id uuid PRIMARY KEY REFERENCES henvalt.tenants(id),
  provider text NOT NULL DEFAULT 'SHOPIFY',
  plan_key text NOT NULL DEFAULT 'STARTER',
  recurring_amount numeric NOT NULL DEFAULT 0,
  henvalt_percentage numeric NOT NULL DEFAULT 0,
  usage_cap_amount numeric NOT NULL DEFAULT 0,
  currency character(3) NOT NULL DEFAULT 'USD',
  provider_subscription_id text UNIQUE,
  usage_line_item_id text,
  status text NOT NULL DEFAULT 'PENDING',
  test_mode boolean NOT NULL DEFAULT false,
  activated_at timestamptz,
  cancelled_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  monthly_email_limit integer NOT NULL DEFAULT 2000
);

CREATE TABLE henvalt.pixel_keys (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id uuid NOT NULL,
  key_digest text NOT NULL UNIQUE,
  allowed_origins text[] NOT NULL DEFAULT '{}',
  active boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now(),
  revoked_at timestamptz,
  shopify_web_pixel_id text,
  shopify_connection_id uuid NOT NULL
);

CREATE TABLE henvalt.pixel_rate_limits (
  key_digest text PRIMARY KEY,
  bucket_start timestamptz NOT NULL,
  request_count integer NOT NULL
);

-- Minimal core identity tables mirror the live tenant-only constraints.
CREATE TABLE henvalt.customers (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id uuid NOT NULL,
  shopify_customer_id text,
  email text,
  CONSTRAINT customers_tenant_id_shopify_customer_id_key UNIQUE (tenant_id, shopify_customer_id)
);

CREATE TABLE henvalt.sessions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id uuid NOT NULL,
  customer_id uuid REFERENCES henvalt.customers(id) ON DELETE SET NULL,
  session_reference text NOT NULL,
  CONSTRAINT sessions_tenant_id_session_reference_key UNIQUE (tenant_id, session_reference)
);

CREATE TABLE henvalt.session_aliases (
  tenant_id uuid NOT NULL,
  alias_reference text NOT NULL,
  session_reference text NOT NULL,
  CONSTRAINT session_aliases_pkey PRIMARY KEY (tenant_id, alias_reference),
  CONSTRAINT session_aliases_session_fk
    FOREIGN KEY (tenant_id, session_reference)
    REFERENCES henvalt.sessions(tenant_id, session_reference)
    ON DELETE CASCADE
);

CREATE TABLE henvalt.checkouts (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id uuid NOT NULL,
  customer_id uuid REFERENCES henvalt.customers(id) ON DELETE SET NULL,
  shopify_checkout_id text,
  checkout_token text,
  session_reference text,
  email text,
  CONSTRAINT checkouts_tenant_id_shopify_checkout_id_key UNIQUE (tenant_id, shopify_checkout_id)
);
CREATE UNIQUE INDEX checkouts_tenant_checkout_token_unique
  ON henvalt.checkouts (tenant_id, checkout_token)
  WHERE checkout_token IS NOT NULL;

CREATE TABLE henvalt.canonical_events (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id uuid NOT NULL,
  webhook_event_id uuid,
  event_type text NOT NULL,
  event_class text NOT NULL,
  source text NOT NULL,
  source_event_id text,
  customer_reference text,
  email text,
  anonymous_reference text,
  session_reference text,
  occurred_at timestamptz,
  received_at timestamptz NOT NULL DEFAULT now(),
  value_at_risk numeric,
  currency character,
  payload jsonb NOT NULL DEFAULT '{}'::jsonb,
  metadata jsonb NOT NULL DEFAULT '{}'::jsonb,
  idempotency_key text NOT NULL,
  correlation_id uuid NOT NULL DEFAULT gen_random_uuid(),
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT canonical_events_tenant_id_idempotency_key_key UNIQUE (tenant_id, idempotency_key)
);

-- Contract-compatible stand-in for the existing production finalizer.
-- The candidate wrapper is tested against its real signature and JSON keys.
CREATE FUNCTION henvalt.control_plane_finalize_shopify_oauth_install_expiring_for_owner(
  p_state_hash text,
  p_shop_domain text,
  p_access_token text,
  p_refresh_token text,
  p_access_expires_in integer,
  p_refresh_expires_in integer,
  p_shopify_shop_id text,
  p_scopes text[],
  p_user_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
AS $function$
DECLARE
  v_connection_id uuid;
BEGIN
  SELECT id INTO v_connection_id
  FROM henvalt.shopify_connections
  WHERE shop_domain = p_shop_domain;

  IF v_connection_id IS NULL THEN
    INSERT INTO henvalt.shopify_connections (
      tenant_id, shop_domain, shopify_shop_id, active
    )
    VALUES (p_user_id, p_shop_domain, p_shopify_shop_id, true)
    RETURNING id INTO v_connection_id;
  END IF;

  UPDATE henvalt.shopify_oauth_states
  SET consumed_at = now()
  WHERE state_hash = p_state_hash;

  RETURN jsonb_build_object(
    'installed', true,
    'tenant_id', p_user_id,
    'connection_id', v_connection_id,
    'token_type', 'offline_expiring'
  );
END;
$function$;

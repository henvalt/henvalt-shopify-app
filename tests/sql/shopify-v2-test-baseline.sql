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

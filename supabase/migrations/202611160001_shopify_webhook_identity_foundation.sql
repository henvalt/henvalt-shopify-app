-- HENVALT Shopify webhook identity foundation.
-- PREPARATION MIGRATION: committed to the isolated engineering branch only.
-- Do not apply until the V2 ingress writer, app registry seed, OAuth callback
-- route registration, and operational cutover plan have been reviewed.
-- This migration is additive and intentionally leaves all legacy rows unresolved.

BEGIN;

CREATE TABLE IF NOT EXISTS henvalt.shopify_app_registry (
  app_key text PRIMARY KEY,
  shopify_client_id text NOT NULL UNIQUE,
  webhook_secret_ref text NOT NULL,
  distribution_class text NOT NULL
    CHECK (distribution_class IN ('merchant_custom', 'public', 'test')),
  lifecycle_status text NOT NULL DEFAULT 'pending'
    CHECK (lifecycle_status IN ('pending', 'active', 'rotating', 'retired')),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT shopify_app_registry_app_key_format
    CHECK (app_key ~ '^[a-z][a-z0-9_-]{2,63}$'),
  CONSTRAINT shopify_app_registry_secret_ref_nonempty
    CHECK (length(btrim(webhook_secret_ref)) > 0)
);

COMMENT ON TABLE henvalt.shopify_app_registry IS
  'Server-only Shopify app identities. webhook_secret_ref is a Vault reference, never a decrypted secret.';
COMMENT ON COLUMN henvalt.shopify_app_registry.webhook_secret_ref IS
  'Reference to a secret held in Supabase Vault; must never contain the secret value.';

ALTER TABLE henvalt.shopify_connections
  ADD COLUMN IF NOT EXISTS app_key text;

CREATE UNIQUE INDEX IF NOT EXISTS shopify_connections_id_tenant_app_key_uidx
  ON henvalt.shopify_connections (id, tenant_id, app_key);

CREATE UNIQUE INDEX IF NOT EXISTS shopify_connections_id_tenant_app_key_domain_uidx
  ON henvalt.shopify_connections (id, tenant_id, app_key, shop_domain);

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conrelid = 'henvalt.shopify_connections'::regclass
      AND conname = 'shopify_connections_app_key_fkey'
  ) THEN
    ALTER TABLE henvalt.shopify_connections
      ADD CONSTRAINT shopify_connections_app_key_fkey
      FOREIGN KEY (app_key)
      REFERENCES henvalt.shopify_app_registry(app_key)
      ON UPDATE RESTRICT ON DELETE RESTRICT;
  END IF;
END $$;

CREATE TABLE IF NOT EXISTS henvalt.shopify_webhook_route_tokens (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id uuid NOT NULL,
  connection_id uuid NOT NULL,
  app_key text NOT NULL,
  token_hash text NOT NULL UNIQUE,
  created_at timestamptz NOT NULL DEFAULT now(),
  expires_at timestamptz,
  revoked_at timestamptz,
  last_used_at timestamptz,
  CONSTRAINT shopify_webhook_route_tokens_hash_format
    CHECK (token_hash ~ '^[0-9a-f]{64}$'),
  CONSTRAINT shopify_webhook_route_tokens_expiry_order
    CHECK (expires_at IS NULL OR expires_at > created_at),
  CONSTRAINT shopify_webhook_route_tokens_connection_app_fkey
    FOREIGN KEY (connection_id, tenant_id, app_key)
    REFERENCES henvalt.shopify_connections (id, tenant_id, app_key)
    ON UPDATE RESTRICT ON DELETE RESTRICT,
  CONSTRAINT shopify_webhook_route_tokens_app_fkey
    FOREIGN KEY (app_key)
    REFERENCES henvalt.shopify_app_registry (app_key)
    ON UPDATE RESTRICT ON DELETE RESTRICT
);

CREATE INDEX IF NOT EXISTS shopify_webhook_route_tokens_active_lookup_idx
  ON henvalt.shopify_webhook_route_tokens (token_hash)
  WHERE revoked_at IS NULL;

CREATE INDEX IF NOT EXISTS shopify_webhook_route_tokens_connection_idx
  ON henvalt.shopify_webhook_route_tokens (connection_id, created_at DESC);

COMMENT ON TABLE henvalt.shopify_webhook_route_tokens IS
  'Hashed per-install webhook route bearer tokens. Raw route tokens must never be persisted or logged.';

CREATE TABLE IF NOT EXISTS henvalt.shopify_webhook_deliveries (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id uuid NOT NULL,
  connection_id uuid NOT NULL,
  app_key text NOT NULL,
  shopify_delivery_id text NOT NULL,
  shopify_event_id text,
  topic text NOT NULL,
  shop_domain_header text NOT NULL,
  raw_body_sha256 text NOT NULL,
  hmac_verified_at timestamptz NOT NULL,
  processing_status text NOT NULL DEFAULT 'RECEIVED'
    CHECK (processing_status IN ('RECEIVED', 'PROCESSING', 'PROCESSED', 'RETRYABLE', 'REJECTED')),
  received_at timestamptz NOT NULL DEFAULT now(),
  processed_at timestamptz,
  failure_code text,
  metadata jsonb NOT NULL DEFAULT '{}'::jsonb,
  CONSTRAINT shopify_webhook_deliveries_delivery_id_nonempty
    CHECK (length(btrim(shopify_delivery_id)) > 0),
  CONSTRAINT shopify_webhook_deliveries_topic_nonempty
    CHECK (length(btrim(topic)) > 0),
  CONSTRAINT shopify_webhook_deliveries_shop_domain_format
    CHECK (shop_domain_header = lower(shop_domain_header)
       AND shop_domain_header ~ '^[a-z0-9][a-z0-9.-]*[.]myshopify[.]com$'),
  CONSTRAINT shopify_webhook_deliveries_body_digest_format
    CHECK (raw_body_sha256 ~ '^[0-9a-f]{64}$'),
  CONSTRAINT shopify_webhook_deliveries_connection_app_domain_fkey
    FOREIGN KEY (connection_id, tenant_id, app_key, shop_domain_header)
    REFERENCES henvalt.shopify_connections (id, tenant_id, app_key, shop_domain)
    ON UPDATE RESTRICT ON DELETE RESTRICT,
  CONSTRAINT shopify_webhook_deliveries_app_fkey
    FOREIGN KEY (app_key)
    REFERENCES henvalt.shopify_app_registry (app_key)
    ON UPDATE RESTRICT ON DELETE RESTRICT,
  CONSTRAINT shopify_webhook_deliveries_connection_delivery_key
    UNIQUE (connection_id, shopify_delivery_id)
);

CREATE INDEX IF NOT EXISTS shopify_webhook_deliveries_processing_idx
  ON henvalt.shopify_webhook_deliveries (processing_status, received_at)
  WHERE processing_status IN ('RECEIVED', 'RETRYABLE', 'PROCESSING');

CREATE INDEX IF NOT EXISTS shopify_webhook_deliveries_tenant_received_idx
  ON henvalt.shopify_webhook_deliveries (tenant_id, received_at DESC);

COMMENT ON TABLE henvalt.shopify_webhook_deliveries IS
  'Durable, connection-bound Shopify webhook inbox. A row is inserted only after route binding and app-secret HMAC verification.';

ALTER TABLE henvalt.shopify_app_registry ENABLE ROW LEVEL SECURITY;
ALTER TABLE henvalt.shopify_webhook_route_tokens ENABLE ROW LEVEL SECURITY;
ALTER TABLE henvalt.shopify_webhook_deliveries ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON henvalt.shopify_app_registry FROM PUBLIC, anon, authenticated;
REVOKE ALL ON henvalt.shopify_webhook_route_tokens FROM PUBLIC, anon, authenticated;
REVOKE ALL ON henvalt.shopify_webhook_deliveries FROM PUBLIC, anon, authenticated;

GRANT SELECT, INSERT, UPDATE ON henvalt.shopify_app_registry TO service_role;
GRANT SELECT, INSERT, UPDATE ON henvalt.shopify_webhook_route_tokens TO service_role;
GRANT SELECT, INSERT, UPDATE ON henvalt.shopify_webhook_deliveries TO service_role;

COMMIT;

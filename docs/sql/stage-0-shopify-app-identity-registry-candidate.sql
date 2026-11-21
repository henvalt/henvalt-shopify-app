-- HENVALT Stage 0: Shopify app identity registry and OAuth binding
-- STATUS: PREPARATION BRANCH ONLY — NOT AN APPLIED MIGRATION.
-- Target schema: henvalt (live catalog inspected 2026-11-16).
-- This file is intentionally outside supabase/migrations/.
--
-- Safety invariants:
--   * Do not backfill legacy app_key values until app ownership/provenance is verified.
--   * Do not store Shopify API secrets or access tokens in this registry.
--   * secret_reference is a Vault/secret-manager locator, never secret material.
--   * Existing OAuth states and connections remain valid with app_key NULL.
--   * Keep shopify_connections.shop_domain global uniqueness for rollout v1.
--   * Do not route public_v1 traffic until app-aware OAuth, webhook, refresh,
--     privacy, recovery and delivery callers are deployed and regression-tested.
--
-- This script is a design candidate. It has NOT been executed against Supabase.
-- A production run requires separate authorization, backup/rollback plan,
-- reviewed grants/default privileges, and staged rollout approval.

BEGIN;

CREATE TABLE IF NOT EXISTS henvalt.shopify_app_registry (
  app_key text PRIMARY KEY,
  shopify_client_id text NOT NULL UNIQUE,
  distribution_type text NOT NULL
    CHECK (distribution_type IN ('custom', 'public')),
  secret_reference text NOT NULL,
  active boolean NOT NULL DEFAULT false,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT shopify_app_registry_app_key_format
    CHECK (app_key ~ '^[a-z][a-z0-9_]{1,47}$'),
  CONSTRAINT shopify_app_registry_secret_reference_not_token
    CHECK (
      secret_reference !~* '^(shpat_|shpca_|shpss_|shpua_)'
    )
);

ALTER TABLE henvalt.shopify_connections
  ADD COLUMN IF NOT EXISTS app_key text;

ALTER TABLE henvalt.shopify_oauth_states
  ADD COLUMN IF NOT EXISTS app_key text;

-- A composite candidate key is required before child tables can enforce
-- tenant + connection consistency with composite foreign keys.
DO $migration$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conrelid = 'henvalt.shopify_connections'::regclass
      AND conname = 'shopify_connections_tenant_id_id_key'
  ) THEN
    ALTER TABLE henvalt.shopify_connections
      ADD CONSTRAINT shopify_connections_tenant_id_id_key
      UNIQUE (tenant_id, id);
  END IF;
END
$migration$;

-- Nullable legacy rows are deliberately retained. NOT VALID avoids an
-- immediate historical scan; new non-null app_key values must reference
-- the registry. Validate separately after preflight.
DO $migration$
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
      ON UPDATE RESTRICT
      ON DELETE RESTRICT
      NOT VALID;
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conrelid = 'henvalt.shopify_oauth_states'::regclass
      AND conname = 'shopify_oauth_states_app_key_fkey'
  ) THEN
    ALTER TABLE henvalt.shopify_oauth_states
      ADD CONSTRAINT shopify_oauth_states_app_key_fkey
      FOREIGN KEY (app_key)
      REFERENCES henvalt.shopify_app_registry(app_key)
      ON UPDATE RESTRICT
      ON DELETE RESTRICT
      NOT VALID;
  END IF;
END
$migration$;

-- Registry is backend-only. No client-facing table privileges or RLS policy
-- are introduced. Service-role access is required by trusted server functions.
ALTER TABLE henvalt.shopify_app_registry ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE henvalt.shopify_app_registry FROM PUBLIC, anon, authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE henvalt.shopify_app_registry TO service_role;

COMMIT;

-- Post-apply verification (run only after separately authorized execution):
-- SELECT app_key, shopify_client_id, distribution_type, active,
--        (secret_reference IS NOT NULL) AS has_secret_locator
-- FROM henvalt.shopify_app_registry ORDER BY app_key;
--
-- SELECT conrelid::regclass, conname, convalidated
-- FROM pg_constraint
-- WHERE conname IN (
--   'shopify_connections_tenant_id_id_key',
--   'shopify_connections_app_key_fkey',
--   'shopify_oauth_states_app_key_fkey'
-- );
--
-- Do NOT insert legacy/public app rows in this stage. First prove the exact
-- client ID and secret locator ownership and implement app-aware OAuth state
-- creation/finalization, callback HMAC routing, token refresh and webhook
-- verification in server-side code.

-- HENVALT exact-store lineage foundation for core identity tables.
-- PREPARATION ONLY. Depends on Shopify app/connection identity migration 001.
-- This migration adds nullable lineage and composite relationship guards only.
-- It intentionally does NOT backfill history, replace tenant-only unique keys,
-- or enable V2 writers. Existing V1 ON CONFLICT contracts remain intact.

BEGIN;

-- A composite FK target that proves a connection belongs to the same tenant.
CREATE UNIQUE INDEX IF NOT EXISTS shopify_connections_id_tenant_uidx
  ON henvalt.shopify_connections (id, tenant_id);

ALTER TABLE henvalt.customers
  ADD COLUMN IF NOT EXISTS shopify_connection_id uuid;

ALTER TABLE henvalt.sessions
  ADD COLUMN IF NOT EXISTS shopify_connection_id uuid;

ALTER TABLE henvalt.session_aliases
  ADD COLUMN IF NOT EXISTS shopify_connection_id uuid;

ALTER TABLE henvalt.checkouts
  ADD COLUMN IF NOT EXISTS shopify_connection_id uuid;

ALTER TABLE henvalt.canonical_events
  ADD COLUMN IF NOT EXISTS shopify_connection_id uuid;

-- Stable composite parent keys for same-store references.
CREATE UNIQUE INDEX IF NOT EXISTS customers_id_tenant_connection_uidx
  ON henvalt.customers (id, tenant_id, shopify_connection_id);

CREATE UNIQUE INDEX IF NOT EXISTS sessions_id_tenant_connection_uidx
  ON henvalt.sessions (id, tenant_id, shopify_connection_id);

CREATE UNIQUE INDEX IF NOT EXISTS sessions_tenant_connection_reference_uidx
  ON henvalt.sessions (tenant_id, shopify_connection_id, session_reference);

CREATE UNIQUE INDEX IF NOT EXISTS checkouts_id_tenant_connection_uidx
  ON henvalt.checkouts (id, tenant_id, shopify_connection_id);

CREATE UNIQUE INDEX IF NOT EXISTS canonical_events_id_tenant_connection_uidx
  ON henvalt.canonical_events (id, tenant_id, shopify_connection_id);

-- Store-qualified indexes prepare the later cutover. Old tenant-only unique
-- constraints remain intentionally active until every V1 writer is replaced.
CREATE UNIQUE INDEX IF NOT EXISTS customers_tenant_connection_shopify_id_uidx
  ON henvalt.customers (tenant_id, shopify_connection_id, shopify_customer_id)
  WHERE shopify_connection_id IS NOT NULL AND shopify_customer_id IS NOT NULL;

CREATE UNIQUE INDEX IF NOT EXISTS session_aliases_tenant_connection_alias_uidx
  ON henvalt.session_aliases (tenant_id, shopify_connection_id, alias_reference)
  WHERE shopify_connection_id IS NOT NULL;

CREATE UNIQUE INDEX IF NOT EXISTS checkouts_tenant_connection_shopify_id_uidx
  ON henvalt.checkouts (tenant_id, shopify_connection_id, shopify_checkout_id)
  WHERE shopify_connection_id IS NOT NULL AND shopify_checkout_id IS NOT NULL;

CREATE UNIQUE INDEX IF NOT EXISTS checkouts_tenant_connection_checkout_token_uidx
  ON henvalt.checkouts (tenant_id, shopify_connection_id, checkout_token)
  WHERE shopify_connection_id IS NOT NULL AND checkout_token IS NOT NULL;

CREATE UNIQUE INDEX IF NOT EXISTS canonical_events_tenant_connection_idempotency_uidx
  ON henvalt.canonical_events (tenant_id, shopify_connection_id, idempotency_key)
  WHERE shopify_connection_id IS NOT NULL;

-- All new connection-bearing rows must reference a real connection in the
-- same tenant. NOT VALID preserves unresolved historical rows while enforcing
-- the constraint for subsequent inserts/updates.
DO $constraints$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid='henvalt.customers'::regclass AND conname='customers_connection_tenant_fkey') THEN
    ALTER TABLE henvalt.customers
      ADD CONSTRAINT customers_connection_tenant_fkey
      FOREIGN KEY (shopify_connection_id, tenant_id)
      REFERENCES henvalt.shopify_connections (id, tenant_id)
      ON UPDATE RESTRICT ON DELETE RESTRICT NOT VALID;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid='henvalt.sessions'::regclass AND conname='sessions_connection_tenant_fkey') THEN
    ALTER TABLE henvalt.sessions
      ADD CONSTRAINT sessions_connection_tenant_fkey
      FOREIGN KEY (shopify_connection_id, tenant_id)
      REFERENCES henvalt.shopify_connections (id, tenant_id)
      ON UPDATE RESTRICT ON DELETE RESTRICT NOT VALID;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid='henvalt.session_aliases'::regclass AND conname='session_aliases_connection_tenant_fkey') THEN
    ALTER TABLE henvalt.session_aliases
      ADD CONSTRAINT session_aliases_connection_tenant_fkey
      FOREIGN KEY (shopify_connection_id, tenant_id)
      REFERENCES henvalt.shopify_connections (id, tenant_id)
      ON UPDATE RESTRICT ON DELETE RESTRICT NOT VALID;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid='henvalt.checkouts'::regclass AND conname='checkouts_connection_tenant_fkey') THEN
    ALTER TABLE henvalt.checkouts
      ADD CONSTRAINT checkouts_connection_tenant_fkey
      FOREIGN KEY (shopify_connection_id, tenant_id)
      REFERENCES henvalt.shopify_connections (id, tenant_id)
      ON UPDATE RESTRICT ON DELETE RESTRICT NOT VALID;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid='henvalt.canonical_events'::regclass AND conname='canonical_events_connection_tenant_fkey') THEN
    ALTER TABLE henvalt.canonical_events
      ADD CONSTRAINT canonical_events_connection_tenant_fkey
      FOREIGN KEY (shopify_connection_id, tenant_id)
      REFERENCES henvalt.shopify_connections (id, tenant_id)
      ON UPDATE RESTRICT ON DELETE RESTRICT NOT VALID;
  END IF;
END
$constraints$;

-- Composite references ensure related records cannot cross store boundaries
-- when both parent and child carry a verified connection ID.
DO $relationships$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid='henvalt.sessions'::regclass AND conname='sessions_customer_same_connection_fkey') THEN
    ALTER TABLE henvalt.sessions
      ADD CONSTRAINT sessions_customer_same_connection_fkey
      FOREIGN KEY (customer_id, tenant_id, shopify_connection_id)
      REFERENCES henvalt.customers (id, tenant_id, shopify_connection_id)
      ON UPDATE RESTRICT ON DELETE SET NULL (customer_id) NOT VALID;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid='henvalt.checkouts'::regclass AND conname='checkouts_customer_same_connection_fkey') THEN
    ALTER TABLE henvalt.checkouts
      ADD CONSTRAINT checkouts_customer_same_connection_fkey
      FOREIGN KEY (customer_id, tenant_id, shopify_connection_id)
      REFERENCES henvalt.customers (id, tenant_id, shopify_connection_id)
      ON UPDATE RESTRICT ON DELETE SET NULL (customer_id) NOT VALID;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid='henvalt.session_aliases'::regclass AND conname='session_aliases_session_same_connection_fkey') THEN
    ALTER TABLE henvalt.session_aliases
      ADD CONSTRAINT session_aliases_session_same_connection_fkey
      FOREIGN KEY (tenant_id, shopify_connection_id, session_reference)
      REFERENCES henvalt.sessions (tenant_id, shopify_connection_id, session_reference)
      ON UPDATE RESTRICT ON DELETE CASCADE NOT VALID;
  END IF;
END
$relationships$;

COMMENT ON COLUMN henvalt.customers.shopify_connection_id IS
  'Exact Shopify installation lineage. NULL means historical or unresolved; never infer from email or tenant.';
COMMENT ON COLUMN henvalt.sessions.shopify_connection_id IS
  'Exact Shopify installation lineage. NULL means historical or unresolved; never infer from session reference alone.';
COMMENT ON COLUMN henvalt.session_aliases.shopify_connection_id IS
  'Exact Shopify installation lineage. NULL means historical or unresolved; never infer from alias value alone.';
COMMENT ON COLUMN henvalt.checkouts.shopify_connection_id IS
  'Exact Shopify installation lineage. NULL means historical or unresolved; never infer from checkout token or email.';
COMMENT ON COLUMN henvalt.canonical_events.shopify_connection_id IS
  'Exact Shopify installation lineage. NULL means historical or unresolved; V2 writers must derive it from verified source identity.';

COMMIT;

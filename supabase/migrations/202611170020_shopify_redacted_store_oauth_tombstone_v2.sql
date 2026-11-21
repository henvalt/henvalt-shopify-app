-- HENVALT exact-store shop/redact OAuth resurrection barrier V2.
-- PREPARATION ONLY. A verified shop/redact receipt tombstones that exact app/shop
-- identity so stale or new OAuth states cannot silently reuse the old connection.
-- Reinstall requires a separately reviewed fresh-connection lineage procedure.

BEGIN;

CREATE TABLE IF NOT EXISTS henvalt.shopify_redacted_store_tombstones_v2 (
  app_key text NOT NULL,
  shop_domain text NOT NULL,
  tenant_id uuid NOT NULL,
  connection_id uuid NOT NULL,
  receipt_id uuid NOT NULL,
  created_at timestamptz NOT NULL DEFAULT pg_catalog.now(),
  CONSTRAINT shopify_redacted_store_tombstones_v2_pkey
    PRIMARY KEY (app_key, shop_domain),
  CONSTRAINT shopify_redacted_store_tombstones_v2_receipt_key
    UNIQUE (receipt_id),
  CONSTRAINT shopify_redacted_store_tombstones_v2_connection_fkey
    FOREIGN KEY (connection_id, tenant_id, app_key, shop_domain)
    REFERENCES henvalt.shopify_connections (id, tenant_id, app_key, shop_domain)
    ON UPDATE RESTRICT ON DELETE RESTRICT,
  CONSTRAINT shopify_redacted_store_tombstones_v2_receipt_fkey
    FOREIGN KEY (receipt_id)
    REFERENCES henvalt.shopify_privacy_webhook_deliveries(id)
    ON UPDATE RESTRICT ON DELETE RESTRICT
);

ALTER TABLE henvalt.shopify_redacted_store_tombstones_v2 ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON henvalt.shopify_redacted_store_tombstones_v2
  FROM PUBLIC, anon, authenticated, service_role;

CREATE OR REPLACE FUNCTION henvalt.tombstone_shopify_redacted_oauth_state_v2()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
BEGIN
  IF EXISTS (
    SELECT 1
    FROM henvalt.shopify_redacted_store_tombstones_v2 t
    WHERE t.shop_domain = NEW.shop_domain
      AND (NEW.app_key IS NULL OR t.app_key = NEW.app_key)
  ) THEN
    RAISE EXCEPTION 'shopify_store_redacted_reinstall_requires_new_connection_lineage'
      USING ERRCODE = '55000';
  END IF;
  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS shopify_redacted_store_oauth_state_barrier_v2
  ON henvalt.shopify_oauth_states;
CREATE TRIGGER shopify_redacted_store_oauth_state_barrier_v2
BEFORE INSERT OR UPDATE OF consumed_at ON henvalt.shopify_oauth_states
FOR EACH ROW
EXECUTE FUNCTION henvalt.tombstone_shopify_redacted_oauth_state_v2();

CREATE OR REPLACE FUNCTION henvalt.record_shopify_redacted_store_tombstone_v2()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
BEGIN
  IF NEW.topic <> 'shop/redact'
     OR NEW.connection_id IS NULL
     OR NEW.tenant_id IS NULL
     OR NEW.app_key IS NULL
     OR NEW.shop_domain IS NULL THEN
    RETURN NEW;
  END IF;

  INSERT INTO henvalt.shopify_redacted_store_tombstones_v2 (
    app_key, shop_domain, tenant_id, connection_id, receipt_id
  )
  SELECT NEW.app_key, NEW.shop_domain, NEW.tenant_id, sc.id, NEW.id
  FROM henvalt.shopify_connections sc
  WHERE sc.id = NEW.connection_id
    AND sc.tenant_id = NEW.tenant_id
    AND sc.app_key = NEW.app_key
    AND sc.shop_domain = NEW.shop_domain
  ON CONFLICT (app_key, shop_domain) DO NOTHING;

  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS shopify_redacted_store_tombstone_after_receipt_v2
  ON henvalt.shopify_privacy_webhook_deliveries;
CREATE TRIGGER shopify_redacted_store_tombstone_after_receipt_v2
AFTER INSERT ON henvalt.shopify_privacy_webhook_deliveries
FOR EACH ROW
WHEN (NEW.topic = 'shop/redact')
EXECUTE FUNCTION henvalt.record_shopify_redacted_store_tombstone_v2();

REVOKE ALL ON FUNCTION henvalt.tombstone_shopify_redacted_oauth_state_v2()
  FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION henvalt.record_shopify_redacted_store_tombstone_v2()
  FROM PUBLIC, anon, authenticated, service_role;

COMMENT ON TABLE henvalt.shopify_redacted_store_tombstones_v2 IS
  'Exact app/shop tombstones created by verified shop/redact receipts. Blocks stale/new OAuth states from reusing the redacted connection until a separately reviewed fresh-lineage procedure exists.';

COMMIT;

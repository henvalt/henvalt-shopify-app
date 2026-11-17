-- HENVALT exact-store Shopify app/uninstalled processor V2.
-- PREPARATION ONLY. Depends on candidate migrations 001, 006, 009, 012, 015 and 017.
-- Runs only after the route-token + app-secret HMAC inbox has inserted a verified receipt.
-- It stops one connection; it does not delete merchant data or other stores.

BEGIN;

CREATE OR REPLACE FUNCTION henvalt.process_shopify_uninstall_receipt_v2()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
BEGIN
  IF NEW.topic <> 'app/uninstalled' THEN
    RETURN NEW;
  END IF;

  -- Lock and re-bind the immutable exact connection lineage from the receipt.
  PERFORM 1
  FROM henvalt.shopify_connections sc
  WHERE sc.id = NEW.connection_id
    AND sc.tenant_id = NEW.tenant_id
    AND sc.app_key = NEW.app_key
    AND sc.shop_domain = NEW.shop_domain_header
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'verified uninstall receipt has no exact connection';
  END IF;

  -- Disable only this Shopify installation.
  UPDATE henvalt.shopify_connections
     SET active = false,
         updated_at = pg_catalog.now()
   WHERE id = NEW.connection_id
     AND tenant_id = NEW.tenant_id
     AND app_key = NEW.app_key
     AND shop_domain = NEW.shop_domain_header;

  UPDATE henvalt.shopify_webhook_route_tokens
     SET revoked_at = COALESCE(revoked_at, pg_catalog.now())
   WHERE connection_id = NEW.connection_id
     AND tenant_id = NEW.tenant_id
     AND app_key = NEW.app_key
     AND revoked_at IS NULL;

  UPDATE henvalt.pixel_keys
     SET active = false,
         revoked_at = COALESCE(revoked_at, pg_catalog.now())
   WHERE shopify_connection_id = NEW.connection_id
     AND tenant_id = NEW.tenant_id
     AND active IS TRUE;

  UPDATE henvalt.shopify_checkout_recovery_candidate_v2
     SET state = 'STORE_INACTIVE',
         updated_at = pg_catalog.now()
   WHERE shopify_connection_id = NEW.connection_id
     AND tenant_id = NEW.tenant_id
     AND state = 'READY_FOR_CONTACT_RESOLUTION';

  UPDATE henvalt.shopify_recovery_opportunity_v2
     SET status = 'CLOSED',
         updated_at = pg_catalog.now()
   WHERE shopify_connection_id = NEW.connection_id
     AND tenant_id = NEW.tenant_id
     AND status IN ('CONTACT_RESOLUTION_PENDING', 'REVIEW_REQUIRED');

  -- Cancel only interventions that have not consumed a delivery permit.
  -- AUTHORIZED attempts may already be in flight and are deliberately not rewritten.
  UPDATE henvalt.shopify_recovery_intervention_v2 i
     SET status = 'CANCELLED',
         updated_at = pg_catalog.now()
   WHERE i.shopify_connection_id = NEW.connection_id
     AND i.tenant_id = NEW.tenant_id
     AND i.status = 'READY_FOR_AUTHORIZATION'
     AND NOT EXISTS (
       SELECT 1
       FROM henvalt.shopify_recovery_send_attempt_v2 a
       WHERE a.intervention_id = i.id
         AND a.tenant_id = i.tenant_id
         AND a.shopify_connection_id = i.shopify_connection_id
     );

  -- Remove both unused and consumed permit material (token hash + recipient fingerprint).
  -- Send attempts and merchant cost reservations remain intact for audit/accounting.
  DELETE FROM henvalt.shopify_delivery_permits_v2
   WHERE shopify_connection_id = NEW.connection_id
     AND tenant_id = NEW.tenant_id;

  UPDATE henvalt.shopify_webhook_deliveries
     SET processing_status = 'PROCESSED',
         processed_at = pg_catalog.now(),
         failure_code = NULL,
         metadata = COALESCE(metadata, '{}'::jsonb)
           || jsonb_build_object('uninstall_processor', 'EXACT_STORE_V2')
   WHERE id = NEW.id
     AND connection_id = NEW.connection_id
     AND tenant_id = NEW.tenant_id
     AND app_key = NEW.app_key;

  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS shopify_exact_store_uninstall_after_receipt_v2
  ON henvalt.shopify_webhook_deliveries;
CREATE TRIGGER shopify_exact_store_uninstall_after_receipt_v2
AFTER INSERT ON henvalt.shopify_webhook_deliveries
FOR EACH ROW
WHEN (NEW.topic = 'app/uninstalled')
EXECUTE FUNCTION henvalt.process_shopify_uninstall_receipt_v2();

REVOKE ALL ON FUNCTION henvalt.process_shopify_uninstall_receipt_v2()
  FROM PUBLIC, anon, authenticated, service_role;

COMMENT ON FUNCTION henvalt.process_shopify_uninstall_receipt_v2() IS
  'After verified app/uninstalled receipt insertion, deactivates only its exact Shopify connection, revokes that install route tokens and pixel keys, closes pending recovery work and deletes permit fingerprints. No tenant-wide deletion.';

COMMIT;

-- HENVALT exact-store shop/redact stop boundary V2.
-- PREPARATION ONLY. Stops one Shopify connection after a verified shop/redact
-- receipt; it does not delete customer, merchant, accounting, or audit data.

BEGIN;

CREATE OR REPLACE FUNCTION henvalt.process_shopify_shop_redact_stop_v2()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
BEGIN
  IF NEW.topic <> 'shop/redact' THEN
    RETURN NEW;
  END IF;

  -- Bind the verified receipt to the immutable installation before any stop.
  IF NEW.connection_id IS NULL
     OR NEW.tenant_id IS NULL
     OR NEW.app_key IS NULL
     OR NEW.shop_domain IS NULL THEN
    -- Preserve an unlinked receipt for manual review; never guess a store.
    RETURN NEW;
  END IF;

  PERFORM 1
  FROM henvalt.shopify_connections sc
  WHERE sc.id = NEW.connection_id
    AND sc.tenant_id = NEW.tenant_id
    AND sc.app_key = NEW.app_key
    AND sc.shop_domain = NEW.shop_domain
  FOR UPDATE;

  IF NOT FOUND THEN
    -- A verified but unbound receipt remains queued for review. Do not stop
    -- any other installation based on partial or conflicting identity.
    RETURN NEW;
  END IF;

  -- Fail closed for this store only while the full retention-safe redaction
  -- processor remains blocked. The privacy queue stays open for review.
  UPDATE henvalt.shopify_connections
     SET active = false,
         updated_at = pg_catalog.now()
   WHERE id = NEW.connection_id
     AND tenant_id = NEW.tenant_id
     AND app_key = NEW.app_key
     AND shop_domain = NEW.shop_domain;

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

  -- Preserve attempts that may already have crossed the provider boundary.
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

  -- Permit tokens/fingerprints are transient authorization material. Attempts
  -- and their cost reservations remain as audit/accounting evidence.
  DELETE FROM henvalt.shopify_delivery_permits_v2
   WHERE shopify_connection_id = NEW.connection_id
     AND tenant_id = NEW.tenant_id;

  UPDATE henvalt.shopify_privacy_webhook_deliveries
     SET processing_status = 'PROCESSING',
         failure_code = NULL
   WHERE id = NEW.id
     AND connection_id = NEW.connection_id
     AND tenant_id = NEW.tenant_id
     AND app_key = NEW.app_key
     AND processing_status = 'REVIEW_REQUIRED';

  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS shopify_exact_store_shop_redact_after_receipt_v2
  ON henvalt.shopify_privacy_webhook_deliveries;
CREATE TRIGGER shopify_exact_store_shop_redact_after_receipt_v2
AFTER INSERT ON henvalt.shopify_privacy_webhook_deliveries
FOR EACH ROW
WHEN (NEW.topic = 'shop/redact')
EXECUTE FUNCTION henvalt.process_shopify_shop_redact_stop_v2();

REVOKE ALL ON FUNCTION henvalt.process_shopify_shop_redact_stop_v2()
  FROM PUBLIC, anon, authenticated, service_role;

COMMENT ON FUNCTION henvalt.process_shopify_shop_redact_stop_v2() IS
  'After a verified shop/redact receipt, disables only its exact Shopify connection, revokes that install route and pixel keys, closes pending recovery work and removes transient permits. It does not delete customer or accounting data and leaves privacy completion blocked.';

COMMIT;

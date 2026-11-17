-- HENVALT settle provider-cost reservations when an ambiguous send is reconciled.
-- PREPARATION ONLY. A verified provider event proves the provider accepted the send.
-- Only definite FAILED outcomes release cost; ambiguous outcomes remain reserved.

BEGIN;

CREATE OR REPLACE FUNCTION henvalt.sync_shopify_delivery_cost_reservation_v2()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
BEGIN
  IF NEW.status IS DISTINCT FROM OLD.status THEN
    UPDATE henvalt.shopify_delivery_cost_reservations_v2
    SET status=CASE
      WHEN NEW.status IN (
        'SUBMITTED','DELIVERED','SOFT_BOUNCED','HARD_BOUNCED',
        'UNSUBSCRIBED','COMPLAINED'
      ) THEN 'SETTLED'
      WHEN NEW.status='FAILED' THEN 'RELEASED'
      WHEN NEW.status='AMBIGUOUS' THEN 'RESERVED'
      ELSE status
    END,
    updated_at=pg_catalog.now()
    WHERE send_attempt_id=NEW.id
      AND tenant_id=NEW.tenant_id
      AND shopify_connection_id=NEW.shopify_connection_id
      AND status IN ('RESERVED','SETTLED');
  END IF;
  RETURN NEW;
END;
$function$;

REVOKE ALL ON FUNCTION henvalt.sync_shopify_delivery_cost_reservation_v2()
  FROM PUBLIC,anon,authenticated,service_role;

COMMENT ON FUNCTION henvalt.sync_shopify_delivery_cost_reservation_v2() IS
  'Keeps provider cost reservations conservative: definite FAILED releases; ambiguous remains reserved; submission or any authenticated provider outcome settles the consumed cost.';

COMMIT;

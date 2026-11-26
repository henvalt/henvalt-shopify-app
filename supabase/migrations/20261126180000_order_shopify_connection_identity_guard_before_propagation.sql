-- Ensure immutable identity guard runs before metadata/connection propagation.
-- PostgreSQL orders same-timing triggers alphabetically; the identity guard must
-- see the attempted UPDATE before a propagation trigger can normalize it.
DO $migration$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY[
    'webhook_events','canonical_events','customers','checkouts','orders','sessions',
    'opportunities','recovery_sequences','recovery_interventions','delivery_requests',
    'delivery_attempts'
  ] LOOP
    EXECUTE format('DROP TRIGGER IF EXISTS trg_shopify_connection_identity_immutable ON henvalt.%I',t);
    EXECUTE format('DROP TRIGGER IF EXISTS trg_00_shopify_connection_identity_immutable ON henvalt.%I',t);
    EXECUTE format(
      'CREATE TRIGGER trg_00_shopify_connection_identity_immutable BEFORE UPDATE ON henvalt.%I FOR EACH ROW EXECUTE FUNCTION henvalt.guard_shopify_connection_identity_immutable()',
      t
    );
  END LOOP;
END
$migration$;

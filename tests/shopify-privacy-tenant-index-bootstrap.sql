\set ON_ERROR_STOP on

-- The disposable interlock fixture is intentionally smaller than production.
-- Supply only the table shape needed to validate this additive index migration.
CREATE TABLE IF NOT EXISTS henvalt.shopify_privacy_requests (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id uuid
);

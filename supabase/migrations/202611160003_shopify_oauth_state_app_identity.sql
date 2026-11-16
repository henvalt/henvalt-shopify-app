-- App identity carried by OAuth state.
-- PREPARATION ONLY: do not apply before the app registry migration and the
-- app-aware OAuth/finalizer implementation have passed review and tests.
-- Nullable preserves legacy OAuth states and historical rows unchanged.

BEGIN;

ALTER TABLE henvalt.shopify_oauth_states
  ADD COLUMN IF NOT EXISTS app_key text;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conrelid = 'henvalt.shopify_oauth_states'::regclass
      AND conname = 'shopify_oauth_states_app_key_fkey'
  ) THEN
    ALTER TABLE henvalt.shopify_oauth_states
      ADD CONSTRAINT shopify_oauth_states_app_key_fkey
      FOREIGN KEY (app_key)
      REFERENCES henvalt.shopify_app_registry(app_key)
      ON UPDATE RESTRICT
      ON DELETE RESTRICT;
  END IF;
END $$;

CREATE INDEX IF NOT EXISTS shopify_oauth_states_app_expiry_idx
  ON henvalt.shopify_oauth_states (app_key, expires_at)
  WHERE app_key IS NOT NULL;

COMMENT ON COLUMN henvalt.shopify_oauth_states.app_key IS
  'Server-resolved Shopify app identity for app-aware OAuth. Null is legacy/unresolved; never accept from browser input.';

COMMIT;

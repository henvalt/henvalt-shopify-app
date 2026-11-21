-- HENVALT provider-send interlock V1 (candidate migration only).
-- Default is CLOSED: no provider credential may be released until an operator
-- explicitly enables sending in an isolated, approved environment.
-- This migration is intentionally NOT applied to the connected production DB.

BEGIN;

CREATE TABLE IF NOT EXISTS henvalt.provider_send_control (
  control_key text PRIMARY KEY CHECK (control_key = 'global'),
  provider_sending_enabled boolean NOT NULL DEFAULT false,
  changed_at timestamptz NOT NULL DEFAULT now(),
  changed_by text,
  change_reason text NOT NULL DEFAULT 'default_deny'
);

INSERT INTO henvalt.provider_send_control (
  control_key, provider_sending_enabled, changed_at, changed_by, change_reason
)
VALUES ('global', false, now(), 'migration', 'default_deny')
ON CONFLICT (control_key) DO NOTHING;

ALTER TABLE henvalt.provider_send_control ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON henvalt.provider_send_control FROM PUBLIC, anon, authenticated, service_role;

COMMENT ON TABLE henvalt.provider_send_control IS
  'Server-only global provider-send interlock. Missing row or false value means deny. No client or service_role direct table access.';

CREATE OR REPLACE FUNCTION henvalt.provider_sending_is_enabled()
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, henvalt, pg_temp
AS $function$
  SELECT COALESCE(
    (SELECT c.provider_sending_enabled
       FROM henvalt.provider_send_control c
      WHERE c.control_key = 'global'),
    false
  );
$function$;

REVOKE ALL ON FUNCTION henvalt.provider_sending_is_enabled() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION henvalt.provider_sending_is_enabled() TO service_role;

CREATE OR REPLACE FUNCTION henvalt.enforce_provider_send_interlock()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, henvalt, pg_temp
AS $function$
BEGIN
  -- A send requires both the authorization claim (PENDING -> UNKNOWN) and
  -- the one-time provider credential claim (provider_claimed_at NULL -> set).
  -- Guard both transitions so the ordinary and manual test-send paths cannot
  -- bypass the interlock by calling the credential RPC directly.
  IF (
    (TG_OP = 'INSERT' AND (
      NEW.status = 'UNKNOWN'
      OR NEW.provider_claimed_at IS NOT NULL
    ))
    OR (TG_OP = 'UPDATE' AND (
      (OLD.status IS DISTINCT FROM NEW.status AND NEW.status = 'UNKNOWN')
      OR (OLD.provider_claimed_at IS NULL AND NEW.provider_claimed_at IS NOT NULL)
    ))
  ) AND NOT henvalt.provider_sending_is_enabled() THEN
    RAISE EXCEPTION 'HENVALT_PROVIDER_SENDING_DISABLED'
      USING ERRCODE = '42501';
  END IF;

  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS delivery_requests_provider_send_interlock
  ON henvalt.delivery_requests;

CREATE TRIGGER delivery_requests_provider_send_interlock
BEFORE INSERT OR UPDATE OF status, provider_claimed_at
ON henvalt.delivery_requests
FOR EACH ROW
EXECUTE FUNCTION henvalt.enforce_provider_send_interlock();

REVOKE ALL ON FUNCTION henvalt.enforce_provider_send_interlock()
  FROM PUBLIC, anon, authenticated, service_role;

COMMIT;

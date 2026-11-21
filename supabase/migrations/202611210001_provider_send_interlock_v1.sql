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

CREATE TABLE IF NOT EXISTS henvalt.provider_send_control_events (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  previous_enabled boolean NOT NULL,
  new_enabled boolean NOT NULL,
  changed_at timestamptz NOT NULL DEFAULT now(),
  changed_by text NOT NULL,
  change_reason text NOT NULL CHECK (length(btrim(change_reason)) BETWEEN 1 AND 500)
);

ALTER TABLE henvalt.provider_send_control_events ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON henvalt.provider_send_control_events FROM PUBLIC, anon, authenticated, service_role;

COMMENT ON TABLE henvalt.provider_send_control_events IS
  'Append-only operator audit trail for global provider-send interlock changes. Server-only.';

CREATE OR REPLACE FUNCTION henvalt.set_provider_sending_enabled(
  p_enabled boolean,
  p_reason text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, henvalt, pg_temp
AS $function$
DECLARE
  v_previous boolean;
  v_actor text := session_user::text;
BEGIN
  IF p_enabled IS NULL
     OR p_reason IS NULL
     OR length(btrim(p_reason)) NOT BETWEEN 1 AND 500 THEN
    RAISE EXCEPTION 'VALID_SEND_CONTROL_CHANGE_REQUIRED'
      USING ERRCODE = '22023';
  END IF;

  SELECT c.provider_sending_enabled
    INTO v_previous
    FROM henvalt.provider_send_control c
   WHERE c.control_key = 'global'
   FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'PROVIDER_SEND_CONTROL_ROW_MISSING'
      USING ERRCODE = '55000';
  END IF;

  UPDATE henvalt.provider_send_control
     SET provider_sending_enabled = p_enabled,
         changed_at = now(),
         changed_by = v_actor,
         change_reason = btrim(p_reason)
   WHERE control_key = 'global';

  INSERT INTO henvalt.provider_send_control_events (
    previous_enabled, new_enabled, changed_at, changed_by, change_reason
  ) VALUES (
    v_previous, p_enabled, now(), v_actor, btrim(p_reason)
  );

  RETURN jsonb_build_object(
    'provider_sending_enabled', p_enabled,
    'previous_enabled', v_previous,
    'changed_by', v_actor,
    'change_reason', btrim(p_reason)
  );
END;
$function$;

-- Deliberately grant no execute permission to PUBLIC, anon, authenticated,
-- or service_role. The database owner/operator uses this from the SQL editor.

REVOKE ALL ON FUNCTION henvalt.set_provider_sending_enabled(boolean, text)
  FROM PUBLIC, anon, authenticated, service_role;

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
DECLARE
  v_send_claim boolean := false;
BEGIN
  -- Check INSERT and UPDATE separately; INSERT has no OLD row.
  IF TG_OP = 'INSERT' THEN
    v_send_claim := NEW.status = 'UNKNOWN'
      OR NEW.provider_claimed_at IS NOT NULL;
  ELSIF TG_OP = 'UPDATE' THEN
    v_send_claim := (
      (OLD.status IS DISTINCT FROM NEW.status AND NEW.status = 'UNKNOWN')
      OR (OLD.provider_claimed_at IS NULL AND NEW.provider_claimed_at IS NOT NULL)
    );
  END IF;

  -- Guard both authorization claim and one-time provider credential claim.
  -- This covers ordinary recovery and manual one-off test-send request paths.
  IF v_send_claim AND NOT henvalt.provider_sending_is_enabled() THEN
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

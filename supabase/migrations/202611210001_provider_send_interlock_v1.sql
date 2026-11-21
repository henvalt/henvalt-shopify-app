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

REVOKE ALL ON FUNCTION henvalt.provider_sending_is_enabled()
  FROM PUBLIC, anon, authenticated, service_role;

-- Serialize credential release against an operator closing the global gate.
-- The shared row lock is held until the credential-release transaction ends;
-- the operator setter takes FOR UPDATE and therefore waits for in-flight claims.
CREATE OR REPLACE FUNCTION henvalt.assert_provider_sending_enabled()
RETURNS void
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, henvalt, pg_temp
AS $function$
DECLARE
  v_enabled boolean;
BEGIN
  SELECT c.provider_sending_enabled
    INTO v_enabled
    FROM henvalt.provider_send_control c
   WHERE c.control_key = 'global'
   FOR SHARE;

  IF NOT FOUND OR v_enabled IS NOT TRUE THEN
    RAISE EXCEPTION 'HENVALT_PROVIDER_SENDING_DISABLED'
      USING ERRCODE = '42501';
  END IF;
END;
$function$;

REVOKE ALL ON FUNCTION henvalt.assert_provider_sending_enabled()
  FROM PUBLIC, anon, authenticated, service_role;

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
    v_send_claim := NEW.status = 'UNKNOWN'
      OR (OLD.provider_claimed_at IS NULL AND NEW.provider_claimed_at IS NOT NULL);
  END IF;

  -- Guard both authorization claim and one-time provider credential claim.
  -- This covers ordinary recovery and manual one-off test-send request paths.
  IF v_send_claim THEN
    PERFORM henvalt.assert_provider_sending_enabled();
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

-- A narrowly scoped, non-secret status surface for the server-side control plane.
-- service_role may observe the gate but cannot change it.
CREATE OR REPLACE FUNCTION henvalt.provider_sending_status()
RETURNS TABLE (
  enabled boolean,
  control_present boolean,
  changed_at timestamptz
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, henvalt, pg_temp
AS $function$
  SELECT COALESCE(c.provider_sending_enabled, false),
         c.control_key IS NOT NULL,
         c.changed_at
    FROM (SELECT 'global'::text AS control_key) expected
    LEFT JOIN henvalt.provider_send_control c
      ON c.control_key = expected.control_key;
$function$;

REVOKE ALL ON FUNCTION henvalt.provider_sending_status()
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION henvalt.provider_sending_status()
  TO service_role;

-- Enforce the documented append-only audit contract at the database boundary.
CREATE OR REPLACE FUNCTION henvalt.reject_provider_send_control_event_mutation()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, henvalt, pg_temp
AS $function$
BEGIN
  RAISE EXCEPTION 'PROVIDER_SEND_CONTROL_AUDIT_IS_APPEND_ONLY'
    USING ERRCODE = '55000';
END;
$function$;

REVOKE ALL ON FUNCTION henvalt.reject_provider_send_control_event_mutation()
  FROM PUBLIC, anon, authenticated, service_role;

DROP TRIGGER IF EXISTS provider_send_control_events_append_only
  ON henvalt.provider_send_control_events;

CREATE TRIGGER provider_send_control_events_append_only
BEFORE UPDATE OR DELETE ON henvalt.provider_send_control_events
FOR EACH ROW
EXECUTE FUNCTION henvalt.reject_provider_send_control_event_mutation();

-- Wrap the actual MailerSend credential-release RPC. The check runs before the
-- legacy implementation can claim a request or read Vault. The legacy body is
-- retained only as a private implementation detail for rollback/review.
ALTER FUNCTION henvalt.get_mailersend_token_for_delivery(uuid, uuid)
  RENAME TO get_mailersend_token_for_delivery_legacy_v1;

REVOKE ALL ON FUNCTION henvalt.get_mailersend_token_for_delivery_legacy_v1(uuid, uuid)
  FROM PUBLIC, anon, authenticated, service_role;

CREATE OR REPLACE FUNCTION henvalt.get_mailersend_token_for_delivery(
  p_tenant_id uuid,
  p_delivery_request_id uuid
)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, henvalt, vault, pg_temp
AS $function$
BEGIN
  PERFORM henvalt.assert_provider_sending_enabled();

  -- The historical manual one-off path is never a production send exemption,
  -- even if an operator opens the global gate for normal recovery traffic.
  IF EXISTS (
    SELECT 1
      FROM henvalt.delivery_requests dr
      JOIN henvalt.messages m
        ON m.id = dr.message_reference
       AND m.tenant_id = dr.tenant_id
     WHERE dr.id = p_delivery_request_id
       AND m.metadata->>'test_only' = 'true'
  ) THEN
    RAISE EXCEPTION 'HENVALT_ONE_OFF_TEST_SEND_DISABLED'
      USING ERRCODE = '42501';
  END IF;

  RETURN henvalt.get_mailersend_token_for_delivery_legacy_v1(
    p_tenant_id, p_delivery_request_id
  );
END;
$function$;

REVOKE ALL ON FUNCTION henvalt.get_mailersend_token_for_delivery(uuid, uuid)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION henvalt.get_mailersend_token_for_delivery(uuid, uuid)
  TO service_role;

COMMIT;

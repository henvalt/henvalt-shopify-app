-- Reserve email quota atomically with the PENDING -> UNKNOWN delivery claim.
-- Candidate only: do not apply to production until the full cutover is approved.
BEGIN;

CREATE TABLE IF NOT EXISTS henvalt.email_usage_reservations (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id uuid NOT NULL,
  delivery_request_id uuid NOT NULL UNIQUE
    REFERENCES henvalt.delivery_requests(id) ON DELETE CASCADE,
  cycle_start timestamptz NOT NULL,
  status text NOT NULL DEFAULT 'RESERVED'
    CHECK (status IN ('RESERVED', 'CONSUMED', 'RELEASED')),
  last_attempt_id uuid,
  status_reason text NOT NULL DEFAULT 'DELIVERY_CLAIMED',
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  consumed_at timestamptz,
  released_at timestamptz
);

CREATE INDEX IF NOT EXISTS email_usage_reservations_tenant_reserved_idx
  ON henvalt.email_usage_reservations (tenant_id, created_at)
  WHERE status = 'RESERVED';

ALTER TABLE henvalt.email_usage_reservations ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON henvalt.email_usage_reservations FROM PUBLIC, anon, authenticated, service_role;

COMMENT ON TABLE henvalt.email_usage_reservations IS
  'Server-only quota holds. RESERVED rows count against the tenant email cap until provider outcome is definitive; no time-based expiry is permitted.';

CREATE OR REPLACE FUNCTION henvalt.enforce_billing_entitlement_before_delivery()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO pg_catalog, henvalt, pg_temp
AS $function$
DECLARE
  v_account henvalt.billing_accounts%ROWTYPE;
  v_cycle_start timestamptz;
  v_measured_fee numeric(18,2) := 0;
  v_email_count integer := 0;
  v_reserved_count integer := 0;
BEGIN
  IF OLD.status = 'PENDING' AND NEW.status = 'UNKNOWN' THEN
    SELECT *
      INTO v_account
      FROM henvalt.billing_accounts
     WHERE tenant_id = NEW.tenant_id
     FOR UPDATE;

    IF NOT FOUND OR NOT (
      v_account.status = 'ACTIVE'
      OR (v_account.status = 'PENDING' AND v_account.test_mode IS TRUE)
    ) THEN
      RAISE EXCEPTION 'HENVALT billing entitlement is not active; delivery denied'
        USING ERRCODE = '42501';
    END IF;

    v_cycle_start := coalesce(v_account.activated_at, now())
      + floor(greatest(0, extract(epoch FROM (
          now() - coalesce(v_account.activated_at, now())
        )) / 2592000)) * interval '30 days';

    SELECT coalesce(sum(bm.henvalt_fee), 0)
      INTO v_measured_fee
      FROM henvalt.billing_measurements bm
     WHERE bm.tenant_id = NEW.tenant_id
       AND bm.currency = v_account.currency
       AND bm.created_at >= v_cycle_start
       AND bm.created_at < v_cycle_start + interval '30 days'
       AND bm.status IN ('MEASURED', 'BILLED');

    IF v_measured_fee >= v_account.usage_cap_amount THEN
      RAISE EXCEPTION 'HENVALT usage cap reached; delivery denied until the next billing interval'
        USING ERRCODE = '42501';
    END IF;

    SELECT count(*)::integer
      INTO v_email_count
      FROM henvalt.email_usage_measurements eum
     WHERE eum.tenant_id = NEW.tenant_id
       AND eum.created_at >= v_cycle_start
       AND eum.created_at < v_cycle_start + interval '30 days';

    -- Count every unresolved hold, including holds created in the prior
    -- interval: a provider request can remain in flight across the boundary.
    -- Once an attempt is measured, its reservation is converted atomically
    -- to CONSUMED and the measurement itself becomes the counted unit.
    SELECT count(*)::integer
      INTO v_reserved_count
      FROM henvalt.email_usage_reservations eur
     WHERE eur.tenant_id = NEW.tenant_id
       AND eur.status = 'RESERVED';

    IF v_email_count + v_reserved_count >= v_account.monthly_email_limit THEN
      RAISE EXCEPTION 'HENVALT email usage limit reached; delivery denied until the next billing interval'
        USING ERRCODE = '42501';
    END IF;

    IF EXISTS (
      SELECT 1
        FROM henvalt.email_usage_reservations eur
       WHERE eur.delivery_request_id = NEW.id
    ) THEN
      RAISE EXCEPTION 'HENVALT email usage reservation already exists for delivery request'
        USING ERRCODE = '23505';
    END IF;

    INSERT INTO henvalt.email_usage_reservations (
      tenant_id, delivery_request_id, cycle_start, status, status_reason
    ) VALUES (
      NEW.tenant_id, NEW.id, v_cycle_start, 'RESERVED', 'DELIVERY_CLAIMED'
    );
  END IF;

  RETURN NEW;
END;
$function$;

REVOKE ALL ON FUNCTION henvalt.enforce_billing_entitlement_before_delivery()
  FROM PUBLIC, anon, authenticated, service_role;

CREATE OR REPLACE FUNCTION henvalt.sync_email_usage_reservation_after_attempt()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO pg_catalog, henvalt, pg_temp
AS $function$
DECLARE
  v_state text := NEW.state::text;
  v_definitive_rejection boolean := false;
BEGIN
  -- Only a narrow allowlist of explicit provider 4xx responses proves that
  -- MailerSend rejected the request. Timeouts, conflicts, rate limits, 5xx,
  -- missing status codes and transport failures remain reserved.
  v_definitive_rejection :=
    v_state IN ('FAILED', 'REJECTED')
    AND NEW.provider_status_code IN (400, 401, 403, 404, 405, 410, 413, 415, 422);

  IF v_state IN ('ACCEPTED', 'DELIVERED', 'UNKNOWN') THEN
    -- A late acceptance/ambiguous result upgrades even a previously released
    -- reservation: evidence of possible provider acceptance always wins.
    UPDATE henvalt.email_usage_reservations
       SET status = 'CONSUMED',
           last_attempt_id = NEW.id,
           status_reason = 'PROVIDER_ACCEPTED_OR_AMBIGUOUS',
           consumed_at = coalesce(consumed_at, NEW.attempted_at),
           released_at = NULL,
           updated_at = now()
     WHERE delivery_request_id = NEW.delivery_request_id
       AND tenant_id = NEW.tenant_id
       AND status IN ('RESERVED', 'RELEASED');
  ELSIF v_definitive_rejection THEN
    -- Never release a reservation after an accepted or ambiguous attempt.
    UPDATE henvalt.email_usage_reservations
       SET status = 'RELEASED',
           last_attempt_id = NEW.id,
           status_reason = 'DEFINITIVE_PROVIDER_REJECTION_' || NEW.provider_status_code::text,
           released_at = coalesce(released_at, NEW.attempted_at),
           updated_at = now()
     WHERE delivery_request_id = NEW.delivery_request_id
       AND tenant_id = NEW.tenant_id
       AND status = 'RESERVED';
  END IF;

  RETURN NEW;
END;
$function$;

REVOKE ALL ON FUNCTION henvalt.sync_email_usage_reservation_after_attempt()
  FROM PUBLIC, anon, authenticated, service_role;

DROP TRIGGER IF EXISTS sync_email_usage_reservation_after_attempt
  ON henvalt.delivery_attempts;

CREATE TRIGGER sync_email_usage_reservation_after_attempt
AFTER INSERT ON henvalt.delivery_attempts
FOR EACH ROW
EXECUTE FUNCTION henvalt.sync_email_usage_reservation_after_attempt();

COMMIT;

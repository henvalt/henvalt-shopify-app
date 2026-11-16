-- REVIEW ONLY: do not apply to the live HENVALT database without separate approval.
-- Purpose: atomically claim Worker -> n8n request IDs after the receiver verifies
-- the exact-byte HMAC. This table is private to trusted server-side code.

BEGIN;

CREATE TABLE IF NOT EXISTS henvalt.internal_ingress_requests (
  request_id uuid PRIMARY KEY,
  signed_at timestamptz NOT NULL,
  received_at timestamptz NOT NULL DEFAULT clock_timestamp()
);

CREATE INDEX IF NOT EXISTS internal_ingress_requests_received_at_idx
  ON henvalt.internal_ingress_requests (received_at);

ALTER TABLE henvalt.internal_ingress_requests ENABLE ROW LEVEL SECURITY;

-- No direct Data API access, including service_role table access. The narrowly
-- scoped SECURITY DEFINER RPC below is the only intended access path.
REVOKE ALL ON TABLE henvalt.internal_ingress_requests
  FROM PUBLIC, anon, authenticated, service_role;

CREATE OR REPLACE FUNCTION henvalt.claim_internal_ingress_request(
  p_request_id uuid,
  p_signed_at timestamptz
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, henvalt
AS $function$
DECLARE
  v_inserted integer;
BEGIN
  IF p_request_id IS NULL OR p_signed_at IS NULL THEN
    RETURN false;
  END IF;

  -- Defense in depth: the receiver also enforces this window before calling.
  IF p_signed_at < clock_timestamp() - interval '5 minutes'
     OR p_signed_at > clock_timestamp() + interval '5 minutes' THEN
    RETURN false;
  END IF;

  -- Bounded cleanup avoids unbounded table growth without a separate workflow.
  WITH expired AS (
    SELECT request_id
    FROM henvalt.internal_ingress_requests
    WHERE received_at < clock_timestamp() - interval '7 days'
    ORDER BY received_at
    LIMIT 500
  )
  DELETE FROM henvalt.internal_ingress_requests AS target
  USING expired
  WHERE target.request_id = expired.request_id;

  INSERT INTO henvalt.internal_ingress_requests (request_id, signed_at)
  VALUES (p_request_id, p_signed_at)
  ON CONFLICT (request_id) DO NOTHING;

  GET DIAGNOSTICS v_inserted = ROW_COUNT;
  RETURN v_inserted = 1;
END;
$function$;

REVOKE ALL ON FUNCTION henvalt.claim_internal_ingress_request(uuid, timestamptz)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION henvalt.claim_internal_ingress_request(uuid, timestamptz)
  TO service_role;

COMMIT;

-- Required preflight before any eventual application:
-- 1. Confirm henvalt schema is exposed only to intended API roles.
-- 2. Confirm service_role has USAGE on schema henvalt.
-- 3. Confirm the function owner is a trusted migration owner with table access.
-- 4. Inspect effective EXECUTE grants and table privileges after application.
-- 5. Test first claim=true, duplicate claim=false, stale/future=false, and that
--    anon/authenticated cannot call the RPC or read/write the table.
-- 6. Confirm no existing object with this name has an incompatible signature.

-- Extend the current replay lease atomically at every fenced business-write boundary.
-- The lease must still be current before extension; stale workers cannot revive it.
CREATE OR REPLACE FUNCTION henvalt.assert_shopify_replay_lease_for_write(
  p_job_id uuid,
  p_worker_id text,
  p_lease_id uuid
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_job henvalt.background_jobs%ROWTYPE;
  v_rows integer;
BEGIN
  IF p_job_id IS NULL OR NULLIF(btrim(p_worker_id), '') IS NULL OR p_lease_id IS NULL THEN
    RAISE EXCEPTION 'SHOPIFY_REPLAY_WRITE_LEASE_ARGUMENTS_INVALID'
      USING ERRCODE = '22023';
  END IF;

  SELECT j.* INTO v_job
    FROM henvalt.background_jobs AS j
   WHERE j.id = p_job_id
     AND j.job_type = 'process_shopify_webhook'
     AND j.status = 'CLAIMED'::henvalt.job_status
     AND j.locked_by = p_worker_id
     AND j.lease_id = p_lease_id
     AND j.lease_expires_at > clock_timestamp()
   FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'SHOPIFY_REPLAY_WRITE_LEASE_NOT_CURRENT'
      USING ERRCODE = '42501';
  END IF;

  -- Heartbeat is part of the same transaction as the downstream business write.
  -- The row lock prevents another worker from reclaiming while this write commits.
  UPDATE henvalt.background_jobs
     SET lease_expires_at = clock_timestamp() + interval '180 seconds',
         updated_at = clock_timestamp()
   WHERE id = p_job_id
     AND job_type = 'process_shopify_webhook'
     AND status = 'CLAIMED'::henvalt.job_status
     AND locked_by = p_worker_id
     AND lease_id = p_lease_id
     AND lease_expires_at > clock_timestamp();

  GET DIAGNOSTICS v_rows = ROW_COUNT;
  IF v_rows <> 1 THEN
    RAISE EXCEPTION 'SHOPIFY_REPLAY_WRITE_LEASE_EXPIRED_DURING_GUARD'
      USING ERRCODE = '42501';
  END IF;
END;
$function$;

REVOKE ALL ON FUNCTION henvalt.assert_shopify_replay_lease_for_write(uuid,text,uuid) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION henvalt.assert_shopify_replay_lease_for_write(uuid,text,uuid) FROM anon, authenticated;
GRANT EXECUTE ON FUNCTION henvalt.assert_shopify_replay_lease_for_write(uuid,text,uuid) TO service_role;

COMMENT ON FUNCTION henvalt.assert_shopify_replay_lease_for_write(uuid,text,uuid) IS
  'Validates and atomically renews the current unexpired Shopify replay lease inside each business-write transaction; stale workers cannot revive an expired lease.';

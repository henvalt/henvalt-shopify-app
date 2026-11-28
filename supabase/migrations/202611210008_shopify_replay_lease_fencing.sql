-- Per-claim lease fencing for Shopify replay jobs only.
-- Existing execute_intervention workers retain the current claim/completion contract.

ALTER TABLE henvalt.background_jobs
  ADD COLUMN IF NOT EXISTS lease_id uuid,
  ADD COLUMN IF NOT EXISTS lease_expires_at timestamptz;

CREATE INDEX IF NOT EXISTS background_jobs_expired_shopify_lease_idx
  ON henvalt.background_jobs (lease_expires_at, priority, created_at)
  WHERE job_type = 'process_shopify_webhook'
    AND status = 'CLAIMED'::henvalt.job_status;

CREATE OR REPLACE FUNCTION henvalt.claim_shopify_replay_job(
  p_worker_id text,
  p_lease_seconds integer DEFAULT 180
)
RETURNS SETOF henvalt.background_jobs
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_worker text := NULLIF(btrim(p_worker_id), '');
  v_lease_seconds integer := LEAST(GREATEST(COALESCE(p_lease_seconds, 180), 30), 900);
BEGIN
  IF v_worker IS NULL THEN
    RAISE EXCEPTION 'SHOPIFY_REPLAY_WORKER_ID_REQUIRED' USING ERRCODE = '22023';
  END IF;

  -- An expired final attempt cannot be reclaimed. Move it out of CLAIMED
  -- atomically so it does not remain stranded with an expired lease forever.
  UPDATE henvalt.background_jobs
     SET status = 'DEAD_LETTER'::henvalt.job_status,
         next_run_at = NULL,
         last_error = 'shopify_replay_lease_expired_after_max_attempts',
         locked_at = NULL,
         locked_by = NULL,
         lease_id = NULL,
         lease_expires_at = NULL,
         updated_at = now()
   WHERE job_type = 'process_shopify_webhook'
     AND status = 'CLAIMED'::henvalt.job_status
     AND lease_expires_at IS NOT NULL
     AND lease_expires_at <= now()
     AND attempts >= max_attempts;

  RETURN QUERY
  WITH candidate AS (
    SELECT j.id
      FROM henvalt.background_jobs j
     WHERE j.job_type = 'process_shopify_webhook'
       AND j.attempts < j.max_attempts
       AND (
         (j.status IN ('QUEUED'::henvalt.job_status, 'RETRY_WAIT'::henvalt.job_status)
           AND j.run_at <= now()
           AND (j.next_run_at IS NULL OR j.next_run_at <= now()))
         OR
         (j.status = 'CLAIMED'::henvalt.job_status
           AND j.lease_expires_at IS NOT NULL
           AND j.lease_expires_at <= now())
       )
     ORDER BY j.priority ASC, j.created_at ASC
     FOR UPDATE SKIP LOCKED
     LIMIT 1
  )
  UPDATE henvalt.background_jobs j
     SET status = 'CLAIMED'::henvalt.job_status,
         attempts = j.attempts + 1,
         locked_at = now(),
         locked_by = v_worker,
         lease_id = gen_random_uuid(),
         lease_expires_at = now() + make_interval(secs => v_lease_seconds),
         next_run_at = NULL,
         updated_at = now()
    FROM candidate c
   WHERE j.id = c.id
  RETURNING j.*;
END;
$function$;

CREATE OR REPLACE FUNCTION henvalt.load_shopify_webhook_replay_job(
  p_job_id uuid,
  p_worker_id text,
  p_lease_id uuid
)
RETURNS TABLE (
  job_id uuid,
  webhook_id uuid,
  tenant_id uuid,
  source_event_id text,
  topic text,
  payload jsonb,
  metadata jsonb,
  processing_status text,
  webhook_processed boolean,
  correlation_id uuid,
  lease_expires_at timestamptz
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_job henvalt.background_jobs%ROWTYPE;
  v_webhook henvalt.webhook_events%ROWTYPE;
  v_webhook_id uuid;
BEGIN
  IF p_job_id IS NULL OR NULLIF(btrim(p_worker_id), '') IS NULL OR p_lease_id IS NULL THEN
    RAISE EXCEPTION 'SHOPIFY_REPLAY_LEASE_ARGUMENTS_INVALID' USING ERRCODE = '22023';
  END IF;

  SELECT j.* INTO v_job
    FROM henvalt.background_jobs j
   WHERE j.id = p_job_id
     AND j.job_type = 'process_shopify_webhook'
     AND j.status = 'CLAIMED'::henvalt.job_status
     AND j.locked_by = p_worker_id
     AND j.lease_id = p_lease_id
     AND j.lease_expires_at > now()
   FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'SHOPIFY_REPLAY_LEASE_NOT_CURRENT' USING ERRCODE = '42501';
  END IF;

  IF v_job.tenant_id IS NULL
     OR COALESCE(v_job.payload->>'webhook_id', '') !~*
       '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' THEN
    RAISE EXCEPTION 'SHOPIFY_REPLAY_JOB_PAYLOAD_INVALID' USING ERRCODE = '22023';
  END IF;

  v_webhook_id := (v_job.payload->>'webhook_id')::uuid;

  SELECT w.* INTO v_webhook
    FROM henvalt.webhook_events w
   WHERE w.id = v_webhook_id
     AND w.tenant_id = v_job.tenant_id
     AND w.source = 'shopify'
   FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'SHOPIFY_REPLAY_WEBHOOK_NOT_FOUND' USING ERRCODE = 'P0002';
  END IF;

  IF v_webhook.metadata->>'ingress_hmac_verified' IS DISTINCT FROM 'true' THEN
    RAISE EXCEPTION 'SHOPIFY_REPLAY_WEBHOOK_NOT_VERIFIED_AT_INGRESS' USING ERRCODE = '42501';
  END IF;

  IF v_webhook.processing_status NOT IN ('PROCESSING', 'FAILED', 'PROCESSED') THEN
    RAISE EXCEPTION 'SHOPIFY_REPLAY_WEBHOOK_STATE_INVALID' USING ERRCODE = '55000';
  END IF;

  RETURN QUERY SELECT
    v_job.id, v_webhook.id, v_webhook.tenant_id, v_webhook.source_event_id,
    v_webhook.topic, v_webhook.payload, v_webhook.metadata,
    v_webhook.processing_status, v_webhook.processing_status = 'PROCESSED',
    v_job.correlation_id, v_job.lease_expires_at;
END;
$function$;

-- The legacy worker-id-only loader is intentionally disabled. Replay workers must
-- present the fresh lease identifier returned by claim_shopify_replay_job().
REVOKE EXECUTE ON FUNCTION henvalt.load_shopify_webhook_replay_job(uuid, text)
  FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION henvalt.load_shopify_webhook_replay_job(uuid, text, uuid) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION henvalt.load_shopify_webhook_replay_job(uuid, text, uuid)
  FROM anon, authenticated;
GRANT EXECUTE ON FUNCTION henvalt.load_shopify_webhook_replay_job(uuid, text, uuid)
  TO service_role;

CREATE OR REPLACE FUNCTION henvalt.complete_shopify_replay_job(
  p_job_id uuid, p_worker_id text, p_lease_id uuid
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE v_count integer;
BEGIN
  UPDATE henvalt.background_jobs
     SET status = 'SUCCEEDED'::henvalt.job_status,
         completed_at = now(), locked_at = NULL, locked_by = NULL,
         lease_id = NULL, lease_expires_at = NULL, updated_at = now()
   WHERE id = p_job_id
     AND job_type = 'process_shopify_webhook'
     AND status = 'CLAIMED'::henvalt.job_status
     AND locked_by = p_worker_id
     AND lease_id = p_lease_id
     AND lease_expires_at > now();
  GET DIAGNOSTICS v_count = ROW_COUNT;
  RETURN v_count = 1;
END;
$function$;

CREATE OR REPLACE FUNCTION henvalt.retry_shopify_replay_job(
  p_job_id uuid, p_worker_id text, p_lease_id uuid,
  p_error text, p_delay_seconds integer DEFAULT 60
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE v_count integer;
BEGIN
  UPDATE henvalt.background_jobs
     SET status = CASE WHEN attempts >= max_attempts
       THEN 'DEAD_LETTER'::henvalt.job_status ELSE 'RETRY_WAIT'::henvalt.job_status END,
         next_run_at = CASE WHEN attempts >= max_attempts THEN NULL
           ELSE now() + make_interval(secs => LEAST(GREATEST(COALESCE(p_delay_seconds,60),0),3600)) END,
         last_error = left(COALESCE(p_error,'unknown_error'),500),
         locked_at = NULL, locked_by = NULL, lease_id = NULL,
         lease_expires_at = NULL, updated_at = now()
   WHERE id = p_job_id
     AND job_type = 'process_shopify_webhook'
     AND status = 'CLAIMED'::henvalt.job_status
     AND locked_by = p_worker_id
     AND lease_id = p_lease_id
     AND lease_expires_at > now();
  GET DIAGNOSTICS v_count = ROW_COUNT;
  RETURN v_count = 1;
END;
$function$;

REVOKE ALL ON FUNCTION henvalt.claim_shopify_replay_job(text, integer) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION henvalt.claim_shopify_replay_job(text, integer) FROM anon, authenticated;
GRANT EXECUTE ON FUNCTION henvalt.claim_shopify_replay_job(text, integer) TO service_role;
REVOKE ALL ON FUNCTION henvalt.complete_shopify_replay_job(uuid, text, uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION henvalt.retry_shopify_replay_job(uuid, text, uuid, text, integer) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION henvalt.complete_shopify_replay_job(uuid, text, uuid) FROM anon, authenticated;
REVOKE EXECUTE ON FUNCTION henvalt.retry_shopify_replay_job(uuid, text, uuid, text, integer) FROM anon, authenticated;
GRANT EXECUTE ON FUNCTION henvalt.complete_shopify_replay_job(uuid, text, uuid) TO service_role;
GRANT EXECUTE ON FUNCTION henvalt.retry_shopify_replay_job(uuid, text, uuid, text, integer) TO service_role;

COMMENT ON FUNCTION henvalt.claim_shopify_replay_job(text, integer) IS
  'Claims one Shopify replay job with a fresh fencing lease; expired claims are atomically reclaimable.';
COMMENT ON FUNCTION henvalt.load_shopify_webhook_replay_job(uuid, text, uuid) IS
  'Loads a replay payload only for the current unexpired per-claim lease.';

CREATE OR REPLACE FUNCTION henvalt.renew_shopify_replay_lease(
  p_job_id uuid, p_worker_id text, p_lease_id uuid,
  p_lease_seconds integer DEFAULT 180
)
RETURNS timestamptz
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_expires timestamptz;
  v_seconds integer := LEAST(GREATEST(COALESCE(p_lease_seconds, 180), 30), 900);
BEGIN
  UPDATE henvalt.background_jobs
     SET lease_expires_at = now() + make_interval(secs => v_seconds),
         updated_at = now()
   WHERE id = p_job_id
     AND job_type = 'process_shopify_webhook'
     AND status = 'CLAIMED'::henvalt.job_status
     AND locked_by = p_worker_id
     AND lease_id = p_lease_id
     AND lease_expires_at > now()
  RETURNING lease_expires_at INTO v_expires;
  RETURN v_expires;
END;
$function$;

REVOKE ALL ON FUNCTION henvalt.renew_shopify_replay_lease(uuid, text, uuid, integer) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION henvalt.renew_shopify_replay_lease(uuid, text, uuid, integer) FROM anon, authenticated;
GRANT EXECUTE ON FUNCTION henvalt.renew_shopify_replay_lease(uuid, text, uuid, integer) TO service_role;

COMMENT ON FUNCTION henvalt.renew_shopify_replay_lease(uuid, text, uuid, integer) IS
  'Extends only the current unexpired Shopify replay lease; cannot revive an expired or superseded lease.';

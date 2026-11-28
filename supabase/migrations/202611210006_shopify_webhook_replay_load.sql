-- Read a Shopify replay payload only when the corresponding replay job is
-- actively claimed by the supplied recovery worker. No client-facing access.

CREATE OR REPLACE FUNCTION henvalt.load_shopify_webhook_replay_job(
  p_job_id uuid,
  p_worker_id text
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
  correlation_id uuid
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
  IF p_job_id IS NULL OR NULLIF(btrim(p_worker_id), '') IS NULL THEN
    RAISE EXCEPTION 'SHOPIFY_REPLAY_CLAIM_ARGUMENTS_INVALID'
      USING ERRCODE = '22023';
  END IF;

  SELECT j.*
    INTO v_job
    FROM henvalt.background_jobs j
   WHERE j.id = p_job_id
     AND j.job_type = 'process_shopify_webhook'
     AND j.status = 'CLAIMED'::henvalt.job_status
     AND j.locked_by = p_worker_id
   FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'SHOPIFY_REPLAY_JOB_NOT_CLAIMED_BY_WORKER'
      USING ERRCODE = '42501';
  END IF;

  IF v_job.tenant_id IS NULL
     OR COALESCE(v_job.payload->>'webhook_id', '') !~*
       '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' THEN
    RAISE EXCEPTION 'SHOPIFY_REPLAY_JOB_PAYLOAD_INVALID'
      USING ERRCODE = '22023';
  END IF;

  v_webhook_id := (v_job.payload->>'webhook_id')::uuid;

  SELECT w.*
    INTO v_webhook
    FROM henvalt.webhook_events w
   WHERE w.id = v_webhook_id
     AND w.tenant_id = v_job.tenant_id
     AND w.source = 'shopify'
   FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'SHOPIFY_REPLAY_WEBHOOK_NOT_FOUND'
      USING ERRCODE = 'P0002';
  END IF;

  IF v_webhook.metadata->>'ingress_hmac_verified' IS DISTINCT FROM 'true' THEN
    RAISE EXCEPTION 'SHOPIFY_REPLAY_WEBHOOK_NOT_VERIFIED_AT_INGRESS'
      USING ERRCODE = '42501';
  END IF;

  IF v_webhook.processing_status NOT IN ('PROCESSING', 'FAILED', 'PROCESSED') THEN
    RAISE EXCEPTION 'SHOPIFY_REPLAY_WEBHOOK_STATE_INVALID'
      USING ERRCODE = '55000';
  END IF;

  RETURN QUERY
  SELECT
    v_job.id,
    v_webhook.id,
    v_webhook.tenant_id,
    v_webhook.source_event_id,
    v_webhook.topic,
    v_webhook.payload,
    v_webhook.metadata,
    v_webhook.processing_status,
    v_webhook.processing_status = 'PROCESSED',
    v_job.correlation_id;
END;
$function$;

REVOKE ALL ON FUNCTION henvalt.load_shopify_webhook_replay_job(uuid, text) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION henvalt.load_shopify_webhook_replay_job(uuid, text) FROM anon, authenticated;
GRANT EXECUTE ON FUNCTION henvalt.load_shopify_webhook_replay_job(uuid, text) TO service_role;

COMMENT ON FUNCTION henvalt.load_shopify_webhook_replay_job(uuid, text) IS
  'Returns a Shopify webhook payload only to the worker holding its claimed replay job, after verifying tenant binding and trusted ingress HMAC marker.';

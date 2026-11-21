-- Atomically pair each newly accepted Shopify webhook with a durable replay job.
-- This migration is candidate-only until explicitly approved and deployed.

CREATE OR REPLACE FUNCTION henvalt.ingest_shopify_webhook_with_replay_job(
  p_tenant_id uuid,
  p_source text,
  p_source_event_id text,
  p_topic text,
  p_idempotency_key text,
  p_payload jsonb,
  p_metadata jsonb DEFAULT '{}'::jsonb
)
RETURNS TABLE (
  webhook_id uuid,
  is_duplicate boolean,
  should_process boolean,
  processing_status text,
  replay_job_id uuid,
  replay_job_status henvalt.job_status
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_ingest record;
  v_job_id uuid;
  v_job_status henvalt.job_status;
  v_job_type text;
  v_job_payload jsonb;
  v_job_key text;
  v_correlation_id uuid;
BEGIN
  IF p_tenant_id IS NULL
     OR NULLIF(p_source, '') IS NULL
     OR NULLIF(p_source_event_id, '') IS NULL
     OR NULLIF(p_topic, '') IS NULL
     OR NULLIF(p_idempotency_key, '') IS NULL
     OR p_payload IS NULL THEN
    RAISE EXCEPTION 'SHOPIFY_WEBHOOK_INGEST_ARGUMENTS_INVALID'
      USING ERRCODE = '22023';
  END IF;

  SELECT *
    INTO v_ingest
    FROM henvalt.ingest_raw_webhook_v2(
      p_tenant_id,
      p_source,
      p_source_event_id,
      p_topic,
      p_idempotency_key,
      p_payload,
      COALESCE(p_metadata, '{}'::jsonb)
    );

  IF NOT FOUND
     OR v_ingest.webhook_id IS NULL
     OR v_ingest.should_process IS NULL
     OR v_ingest.processing_status IS NULL THEN
    RAISE EXCEPTION 'SHOPIFY_WEBHOOK_INGEST_RETURNED_INCOMPLETE_RESULT'
      USING ERRCODE = '55000';
  END IF;

  IF v_ingest.should_process IS TRUE
     AND v_ingest.processing_status <> 'PROCESSING' THEN
    RAISE EXCEPTION 'SHOPIFY_WEBHOOK_INGEST_STATE_INCONSISTENT'
      USING ERRCODE = '55000';
  END IF;

  IF v_ingest.processing_status = 'PROCESSING' THEN
    v_job_key := 'shopify-webhook-replay:' || v_ingest.webhook_id::text;

    IF COALESCE(p_metadata->>'correlation_id', '') ~*
       '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' THEN
      v_correlation_id := (p_metadata->>'correlation_id')::uuid;
    END IF;

    INSERT INTO henvalt.background_jobs (
      tenant_id,
      job_type,
      payload,
      status,
      priority,
      attempts,
      max_attempts,
      run_at,
      correlation_id,
      idempotency_key
    )
    VALUES (
      p_tenant_id,
      'process_shopify_webhook',
      jsonb_build_object('webhook_id', v_ingest.webhook_id),
      'QUEUED'::henvalt.job_status,
      20,
      0,
      5,
      now(),
      v_correlation_id,
      v_job_key
    )
    ON CONFLICT (tenant_id, idempotency_key) DO NOTHING;

    SELECT j.id, j.status, j.job_type, j.payload
      INTO v_job_id, v_job_status, v_job_type, v_job_payload
      FROM henvalt.background_jobs j
     WHERE j.tenant_id = p_tenant_id
       AND j.idempotency_key = v_job_key
     FOR UPDATE;

    IF v_job_id IS NULL
       OR v_job_type <> 'process_shopify_webhook'
       OR v_job_payload->>'webhook_id' <> v_ingest.webhook_id::text THEN
      RAISE EXCEPTION 'SHOPIFY_WEBHOOK_REPLAY_JOB_IDENTITY_MISMATCH'
        USING ERRCODE = '55000';
    END IF;
  END IF;

  RETURN QUERY
  SELECT
    v_ingest.webhook_id,
    v_ingest.is_duplicate,
    v_ingest.should_process,
    v_ingest.processing_status,
    v_job_id,
    v_job_status;
END;
$function$;

REVOKE ALL ON FUNCTION henvalt.ingest_shopify_webhook_with_replay_job(
  uuid, text, text, text, text, jsonb, jsonb
) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION henvalt.ingest_shopify_webhook_with_replay_job(
  uuid, text, text, text, text, jsonb, jsonb
) FROM anon, authenticated;
GRANT EXECUTE ON FUNCTION henvalt.ingest_shopify_webhook_with_replay_job(
  uuid, text, text, text, text, jsonb, jsonb
) TO service_role;

COMMENT ON FUNCTION henvalt.ingest_shopify_webhook_with_replay_job(
  uuid, text, text, text, text, jsonb, jsonb
) IS 'Atomically persists/claims a Shopify webhook and ensures an idempotent process_shopify_webhook background job exists before an ingress 2xx is returned.';

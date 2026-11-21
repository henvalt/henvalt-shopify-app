\set ON_ERROR_STOP on

INSERT INTO henvalt.tenants(id, status)
VALUES ('abababab-abab-4bab-8bab-abababababab', 'ACTIVE')
ON CONFLICT (id) DO NOTHING;

DO $lease_fencing$
DECLARE
  v_webhook uuid;
  v_job uuid;
  v_first record;
  v_second record;
  v_loaded record;
  v_rejected boolean;
BEGIN
  UPDATE henvalt.background_jobs
     SET status = 'SUCCEEDED'::henvalt.job_status,
         locked_by = NULL, locked_at = NULL, lease_id = NULL, lease_expires_at = NULL,
         completed_at = now()
   WHERE job_type = 'process_shopify_webhook'
     AND status IN ('QUEUED'::henvalt.job_status, 'RETRY_WAIT'::henvalt.job_status);

  INSERT INTO henvalt.webhook_events(
    tenant_id, source, source_event_id, topic, idempotency_key,
    payload, metadata, processing_status
  ) VALUES (
    'abababab-abab-4bab-8bab-abababababab',
    'shopify', 'lease-fencing-delivery-001', 'orders/paid',
    'lease-fencing-delivery-001',
    '{"id":"lease-fencing-order","test":true}'::jsonb,
    '{"ingress_hmac_verified":true}'::jsonb,
    'PROCESSING'
  ) RETURNING id INTO v_webhook;

  INSERT INTO henvalt.background_jobs(
    tenant_id, job_type, payload, status, attempts, max_attempts, idempotency_key
  ) VALUES (
    'abababab-abab-4bab-8bab-abababababab',
    'process_shopify_webhook',
    jsonb_build_object('webhook_id', v_webhook),
    'QUEUED', 0, 5, 'lease-fencing-job-001'
  ) RETURNING id INTO v_job;

  SELECT * INTO v_first
    FROM henvalt.claim_shopify_replay_job('worker-old', 60);

  IF v_first.id IS DISTINCT FROM v_job
     OR v_first.lease_id IS NULL
     OR v_first.lease_expires_at <= now()
     OR v_first.locked_by IS DISTINCT FROM 'worker-old' THEN
    RAISE EXCEPTION 'FIRST_LEASE_NOT_ISSUED';
  END IF;

  SELECT * INTO v_loaded
    FROM henvalt.load_shopify_webhook_replay_job(v_job, 'worker-old', v_first.lease_id);

  IF v_loaded.webhook_id IS DISTINCT FROM v_webhook THEN
    RAISE EXCEPTION 'CURRENT_LEASE_COULD_NOT_LOAD_PAYLOAD';
  END IF;

  UPDATE henvalt.background_jobs
     SET lease_expires_at = now() - interval '1 second'
   WHERE id = v_job;

  SELECT * INTO v_second
    FROM henvalt.claim_shopify_replay_job('worker-new', 60);

  IF v_second.id IS DISTINCT FROM v_job
     OR v_second.lease_id IS NULL
     OR v_second.lease_id = v_first.lease_id
     OR v_second.locked_by IS DISTINCT FROM 'worker-new' THEN
    RAISE EXCEPTION 'EXPIRED_JOB_NOT_RECLAIMED_WITH_FRESH_LEASE';
  END IF;

  v_rejected := false;
  BEGIN
    PERFORM * FROM henvalt.load_shopify_webhook_replay_job(v_job, 'worker-old', v_first.lease_id);
  EXCEPTION WHEN insufficient_privilege THEN
    v_rejected := true;
  END;
  IF NOT v_rejected THEN
    RAISE EXCEPTION 'STALE_WORKER_LOADED_PAYLOAD_AFTER_RECLAIM';
  END IF;

  IF henvalt.complete_shopify_replay_job(v_job, 'worker-old', v_first.lease_id) IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'STALE_WORKER_COMPLETED_RECLAIMED_JOB';
  END IF;

  IF henvalt.retry_shopify_replay_job(v_job, 'worker-old', v_first.lease_id, 'stale', 30) IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'STALE_WORKER_RETRIED_RECLAIMED_JOB';
  END IF;

  IF henvalt.complete_shopify_replay_job(v_job, 'worker-new', v_second.lease_id) IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'CURRENT_WORKER_COULD_NOT_COMPLETE_JOB';
  END IF;

  IF EXISTS (
    SELECT 1 FROM henvalt.background_jobs
     WHERE id = v_job
       AND (status <> 'SUCCEEDED'::henvalt.job_status
         OR lease_id IS NOT NULL OR lease_expires_at IS NOT NULL
         OR locked_by IS NOT NULL)
  ) THEN
    RAISE EXCEPTION 'COMPLETED_JOB_RETAINED_ACTIVE_LEASE';
  END IF;

  RAISE NOTICE 'SHOPIFY_REPLAY_LEASE_FENCING_ACCEPTANCE_PASSED';
END;
$lease_fencing$;

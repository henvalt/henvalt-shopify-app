\set ON_ERROR_STOP on

INSERT INTO henvalt.tenants(id, status)
VALUES ('acacacac-acac-4cac-8cac-acacacacacac', 'ACTIVE')
ON CONFLICT (id) DO NOTHING;

DO $write_fencing$
DECLARE
  v_webhook uuid;
  v_job uuid;
  v_old record;
  v_new record;
  v_rejected boolean := false;
BEGIN
  UPDATE henvalt.background_jobs
     SET status = 'SUCCEEDED'::henvalt.job_status,
         locked_by = NULL, locked_at = NULL, lease_id = NULL,
         lease_expires_at = NULL, completed_at = now()
   WHERE job_type = 'process_shopify_webhook'
     AND status IN ('QUEUED'::henvalt.job_status, 'RETRY_WAIT'::henvalt.job_status);

  INSERT INTO henvalt.webhook_events(
    tenant_id, source, source_event_id, topic, idempotency_key,
    payload, metadata, processing_status
  ) VALUES (
    'acacacac-acac-4cac-8cac-acacacacacac',
    'shopify', 'business-write-fence-delivery-001', 'checkouts/update',
    'business-write-fence-delivery-001',
    '{"id":"business-write-fence-checkout","test":true}'::jsonb,
    '{"ingress_hmac_verified":true}'::jsonb,
    'PROCESSING'
  ) RETURNING id INTO v_webhook;

  INSERT INTO henvalt.background_jobs(
    tenant_id, job_type, payload, status, attempts, max_attempts, idempotency_key
  ) VALUES (
    'acacacac-acac-4cac-8cac-acacacacacac',
    'process_shopify_webhook',
    jsonb_build_object('webhook_id',v_webhook),
    'QUEUED',0,5,'business-write-fence-job-001'
  ) RETURNING id INTO v_job;

  SELECT * INTO v_old FROM henvalt.claim_shopify_replay_job('write-worker-old',60);
  IF v_old.id IS DISTINCT FROM v_job OR v_old.lease_id IS NULL THEN
    RAISE EXCEPTION 'BUSINESS_WRITE_TEST_FIRST_CLAIM_FAILED';
  END IF;

  UPDATE henvalt.background_jobs
     SET lease_expires_at = clock_timestamp() - interval '1 second'
   WHERE id = v_job;

  SELECT * INTO v_new FROM henvalt.claim_shopify_replay_job('write-worker-current',60);
  IF v_new.id IS DISTINCT FROM v_job OR v_new.lease_id IS NULL
     OR v_new.lease_id = v_old.lease_id THEN
    RAISE EXCEPTION 'BUSINESS_WRITE_TEST_RECLAIM_FAILED';
  END IF;

  BEGIN
    PERFORM * FROM henvalt.upsert_canonical_event_fenced(
      v_job,'write-worker-old',v_old.lease_id,
      'acacacac-acac-4cac-8cac-acacacacacac',v_webhook,
      'checkouts/update','RECOVERABLE'::henvalt.event_class,'shopify',
      'business-write-fence-source-001',NULL,'stale@example.invalid',NULL,NULL,
      clock_timestamp(),100.00,'USD'::character,
      '{"id":"business-write-fence-checkout","test":true}'::jsonb,'{}'::jsonb,
      'business-write-fence-idempotency-stale',gen_random_uuid()
    );
  EXCEPTION WHEN insufficient_privilege THEN
    v_rejected := true;
  END;

  IF NOT v_rejected THEN
    RAISE EXCEPTION 'STALE_WORKER_WAS_ALLOWED_THROUGH_CANONICAL_WRITE_WRAPPER';
  END IF;

  IF EXISTS (
    SELECT 1 FROM henvalt.canonical_events
     WHERE tenant_id='acacacac-acac-4cac-8cac-acacacacacac'
       AND idempotency_key='business-write-fence-idempotency-stale'
  ) THEN
    RAISE EXCEPTION 'STALE_WORKER_CREATED_CANONICAL_EVENT';
  END IF;

  v_rejected := false;
  BEGIN
    PERFORM henvalt.mark_webhook_failed_fenced(
      v_job,'write-worker-old',v_old.lease_id,v_webhook,'stale worker failure'
    );
  EXCEPTION WHEN insufficient_privilege THEN
    v_rejected := true;
  END;
  IF NOT v_rejected OR NOT EXISTS (
    SELECT 1 FROM henvalt.webhook_events
     WHERE id=v_webhook AND processing_status='PROCESSING'
  ) THEN
    RAISE EXCEPTION 'STALE_WORKER_CHANGED_WEBHOOK_FAILURE_STATE';
  END IF;

  PERFORM * FROM henvalt.upsert_canonical_event_fenced(
    v_job,'write-worker-current',v_new.lease_id,
    'acacacac-acac-4cac-8cac-acacacacacac',v_webhook,
    'checkouts/update','RECOVERABLE'::henvalt.event_class,'shopify',
    'business-write-fence-source-001',NULL,'current@example.invalid',NULL,NULL,
    clock_timestamp(),100.00,'USD'::character,
    '{"id":"business-write-fence-checkout","test":true}'::jsonb,'{}'::jsonb,
    'business-write-fence-idempotency-current',gen_random_uuid()
  );

  IF NOT EXISTS (
    SELECT 1 FROM henvalt.canonical_events
     WHERE tenant_id='acacacac-acac-4cac-8cac-acacacacacac'
       AND idempotency_key='business-write-fence-idempotency-current'
  ) THEN
    RAISE EXCEPTION 'CURRENT_WORKER_COULD_NOT_COMMIT_FENCED_CANONICAL_EVENT';
  END IF;

  IF henvalt.mark_webhook_processed_fenced(
    v_job,'write-worker-current',v_new.lease_id,v_webhook
  ) IS DISTINCT FROM true OR NOT EXISTS (
    SELECT 1 FROM henvalt.webhook_events
     WHERE id=v_webhook AND processing_status='PROCESSED'
  ) THEN
    RAISE EXCEPTION 'CURRENT_WORKER_COULD_NOT_MARK_WEBHOOK_PROCESSED';
  END IF;

  RAISE NOTICE 'SHOPIFY_REPLAY_BUSINESS_WRITE_FENCING_ACCEPTANCE_PASSED';
END;
$write_fencing$;


INSERT INTO henvalt.tenants(id, status)
VALUES ('cdcdcdcd-cdcd-4dcd-8dcd-cdcdcdcdcdcd', 'ACTIVE')
ON CONFLICT (id) DO NOTHING;

-- These fixed IDs are real tenant-owned targets for the successful current-worker
-- path. The previous fixture passed UUIDs that did not exist, which the new
-- object-tenant guard correctly rejects before the legacy-write stub is called.
INSERT INTO henvalt.opportunities(id,tenant_id,opportunity_type,status)
VALUES
  ('11111111-1111-4111-8111-111111111111','cdcdcdcd-cdcd-4dcd-8dcd-cdcdcdcdcdcd','ABANDONED_CHECKOUT','ELIGIBLE')
ON CONFLICT (id) DO UPDATE SET tenant_id=EXCLUDED.tenant_id;

INSERT INTO henvalt.order_attributions(id,tenant_id,order_id,attribution_confidence)
VALUES (
  '33333333-3333-4333-8333-333333333333',
  'cdcdcdcd-cdcd-4dcd-8dcd-cdcdcdcdcdcd',
  '44444444-4444-4444-8444-444444444444',
  'HIGH'
)
ON CONFLICT (id) DO UPDATE SET tenant_id=EXCLUDED.tenant_id;

DO $complete_ingest_fencing$
DECLARE
  v_webhook uuid;
  v_job uuid;
  v_old record;
  v_new record;
  v_rejected boolean;
  v_calls integer;
  v_result boolean;
  v_sequence uuid;
  v_ledger jsonb;
  v_lease_before timestamptz;
  v_lease_after timestamptz;
BEGIN
  UPDATE henvalt.background_jobs
     SET status = 'SUCCEEDED'::henvalt.job_status,
         locked_by = NULL, locked_at = NULL, lease_id = NULL,
         lease_expires_at = NULL, completed_at = now()
   WHERE job_type = 'process_shopify_webhook'
     AND status <> 'SUCCEEDED'::henvalt.job_status;

  INSERT INTO henvalt.webhook_events(
    tenant_id, source, source_event_id, topic, idempotency_key,
    payload, metadata, processing_status
  ) VALUES (
    'cdcdcdcd-cdcd-4dcd-8dcd-cdcdcdcdcdcd',
    'shopify', 'complete-ingest-fence-delivery-001', 'orders/create',
    'complete-ingest-fence-delivery-001',
    '{"id":"complete-ingest-fence-order","test":true}'::jsonb,
    '{"ingress_hmac_verified":true}'::jsonb,
    'PROCESSING'
  ) RETURNING id INTO v_webhook;

  INSERT INTO henvalt.background_jobs(
    tenant_id, job_type, payload, status, attempts, max_attempts, idempotency_key
  ) VALUES (
    'cdcdcdcd-cdcd-4dcd-8dcd-cdcdcdcdcdcd',
    'process_shopify_webhook',
    jsonb_build_object('webhook_id',v_webhook),
    'QUEUED',0,5,'complete-ingest-fence-job-001'
  ) RETURNING id INTO v_job;

  SELECT * INTO v_old FROM henvalt.claim_shopify_replay_job('complete-old-worker',60);
  IF v_old.id IS DISTINCT FROM v_job OR v_old.lease_id IS NULL THEN
    RAISE EXCEPTION 'COMPLETE_INGEST_FENCE_FIRST_CLAIM_FAILED';
  END IF;

  UPDATE henvalt.background_jobs
     SET lease_expires_at = clock_timestamp() - interval '1 second'
   WHERE id = v_job;

  SELECT * INTO v_new FROM henvalt.claim_shopify_replay_job('complete-current-worker',60);
  IF v_new.id IS DISTINCT FROM v_job OR v_new.lease_id IS NULL
     OR v_new.lease_id = v_old.lease_id THEN
    RAISE EXCEPTION 'COMPLETE_INGEST_FENCE_RECLAIM_FAILED';
  END IF;

  DELETE FROM henvalt.replay_fence_test_calls;

  v_rejected := false;
  BEGIN
    PERFORM henvalt.apply_eligibility_fenced(
      v_job,'complete-old-worker',v_old.lease_id,
      '11111111-1111-4111-8111-111111111111','ELIGIBLE'::henvalt.opportunity_status
    );
  EXCEPTION WHEN insufficient_privilege THEN v_rejected := true;
  END;
  IF NOT v_rejected THEN RAISE EXCEPTION 'STALE_APPLY_ELIGIBILITY_WAS_NOT_REJECTED'; END IF;

  v_rejected := false;
  BEGIN
    PERFORM henvalt.create_recovery_sequence_fenced(
      v_job,'complete-old-worker',v_old.lease_id,'22222222-2222-4222-8222-222222222222'
    );
  EXCEPTION WHEN insufficient_privilege THEN v_rejected := true;
  END;
  IF NOT v_rejected THEN RAISE EXCEPTION 'STALE_CREATE_RECOVERY_SEQUENCE_WAS_NOT_REJECTED'; END IF;

  v_rejected := false;
  BEGIN
    PERFORM henvalt.post_recovery_to_ledger_and_measure_billing_fenced(
      v_job,'complete-old-worker',v_old.lease_id,'33333333-3333-4333-8333-333333333333'
    );
  EXCEPTION WHEN insufficient_privilege THEN v_rejected := true;
  END;
  IF NOT v_rejected THEN RAISE EXCEPTION 'STALE_REVENUE_LEDGER_WRITE_WAS_NOT_REJECTED'; END IF;

  v_rejected := false;
  BEGIN
    PERFORM henvalt.defer_payment_webhook_reconciliation_fenced(
      v_job,'complete-old-worker',v_old.lease_id,v_webhook,'stale payment reconciliation'
    );
  EXCEPTION WHEN insufficient_privilege THEN v_rejected := true;
  END;
  IF NOT v_rejected THEN RAISE EXCEPTION 'STALE_PAYMENT_RECONCILIATION_WAS_NOT_REJECTED'; END IF;

  SELECT count(*) INTO v_calls FROM henvalt.replay_fence_test_calls;
  IF v_calls <> 0 THEN RAISE EXCEPTION 'STALE_WORKER_REACHED_LEGACY_INGEST_WRITES: %',v_calls; END IF;

  v_lease_before := v_new.lease_expires_at;
  v_result := henvalt.apply_eligibility_fenced(
    v_job,'complete-current-worker',v_new.lease_id,
    '11111111-1111-4111-8111-111111111111','ELIGIBLE'::henvalt.opportunity_status
  );
  IF v_result IS DISTINCT FROM true THEN RAISE EXCEPTION 'CURRENT_APPLY_ELIGIBILITY_FAILED'; END IF;
  SELECT lease_expires_at INTO v_lease_after
    FROM henvalt.background_jobs WHERE id = v_job;
  IF v_lease_after <= v_lease_before THEN
    RAISE EXCEPTION 'FENCED_BUSINESS_WRITE_DID_NOT_RENEW_REPLAY_LEASE';
  END IF;

  v_sequence := henvalt.create_recovery_sequence_fenced(
    v_job,'complete-current-worker',v_new.lease_id,'22222222-2222-4222-8222-222222222222'
  );
  IF v_sequence IS DISTINCT FROM 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'::uuid THEN
    RAISE EXCEPTION 'CURRENT_CREATE_RECOVERY_SEQUENCE_FAILED';
  END IF;

  v_ledger := henvalt.post_recovery_to_ledger_and_measure_billing_fenced(
    v_job,'complete-current-worker',v_new.lease_id,'33333333-3333-4333-8333-333333333333'
  );
  IF v_ledger->>'billing_measured' IS DISTINCT FROM 'true' THEN
    RAISE EXCEPTION 'CURRENT_REVENUE_LEDGER_WRITE_FAILED';
  END IF;

  v_result := henvalt.defer_payment_webhook_reconciliation_fenced(
    v_job,'complete-current-worker',v_new.lease_id,v_webhook,'synthetic payment reconciliation'
  );
  IF v_result IS DISTINCT FROM true THEN RAISE EXCEPTION 'CURRENT_PAYMENT_RECONCILIATION_FAILED'; END IF;

  SELECT count(*) INTO v_calls FROM henvalt.replay_fence_test_calls;
  IF v_calls <> 4 THEN RAISE EXCEPTION 'CURRENT_WORKER_DID_NOT_REACH_ALL_FOUR_LEGACY_WRITES: %',v_calls; END IF;

  RAISE NOTICE 'SHOPIFY_REPLAY_COMPLETE_INGEST_WRITE_FENCING_ACCEPTANCE_PASSED';
END;
$complete_ingest_fencing$;

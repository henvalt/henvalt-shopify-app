\set ON_ERROR_STOP on

INSERT INTO henvalt.tenants (id, status)
VALUES ('cccccccc-cccc-4ccc-8ccc-cccccccccccc', 'ACTIVE')
ON CONFLICT (id) DO NOTHING;

DO $replay_loader$
DECLARE
  v_ingest record;
  v_claim record;
  v_loaded record;
  v_failed boolean := false;
  v_function text := 'henvalt.load_shopify_webhook_replay_job(uuid,text)';
  v_worker text := 'henvalt_replay_acceptance_worker';
BEGIN
  SELECT * INTO v_ingest
    FROM henvalt.ingest_shopify_webhook_with_replay_job(
      'cccccccc-cccc-4ccc-8ccc-cccccccccccc',
      'shopify',
      'delivery-loader-001',
      'orders/paid',
      'shopify:loader-001',
      '{"id":"order-loader-001","test":true}'::jsonb,
      '{"correlation_id":"dddddddd-dddd-4ddd-8ddd-dddddddddddd"}'::jsonb
    );

  IF v_ingest.replay_job_id IS NULL THEN
    RAISE EXCEPTION 'REPLAY_LOADER_FIXTURE_JOB_MISSING';
  END IF;

  SELECT * INTO v_claim
    FROM henvalt.claim_next_job(v_worker, ARRAY['process_shopify_webhook']::text[]);

  IF v_claim.id IS DISTINCT FROM v_ingest.replay_job_id
     OR v_claim.status IS DISTINCT FROM 'CLAIMED'::henvalt.job_status
     OR v_claim.locked_by IS DISTINCT FROM v_worker THEN
    RAISE EXCEPTION 'REPLAY_JOB_NOT_CLAIMED_BY_EXPECTED_WORKER';
  END IF;

  SELECT * INTO v_loaded
    FROM henvalt.load_shopify_webhook_replay_job(v_claim.id, v_worker);

  IF v_loaded.webhook_id IS DISTINCT FROM v_ingest.webhook_id
     OR v_loaded.tenant_id IS DISTINCT FROM 'cccccccc-cccc-4ccc-8ccc-cccccccccccc'::uuid
     OR v_loaded.source_event_id IS DISTINCT FROM 'delivery-loader-001'
     OR v_loaded.topic IS DISTINCT FROM 'orders/paid'
     OR v_loaded.webhook_processed IS DISTINCT FROM false
     OR v_loaded.payload->>'id' IS DISTINCT FROM 'order-loader-001' THEN
    RAISE EXCEPTION 'REPLAY_LOADER_RETURNED_WRONG_OR_INCOMPLETE_WEBHOOK';
  END IF;

  BEGIN
    PERFORM *
      FROM henvalt.load_shopify_webhook_replay_job(v_claim.id, 'wrong-worker');
  EXCEPTION WHEN insufficient_privilege THEN
    v_failed := true;
  END;

  IF NOT v_failed THEN
    RAISE EXCEPTION 'REPLAY_LOADER_ACCEPTED_NON_OWNER_WORKER';
  END IF;

  UPDATE henvalt.webhook_events
     SET metadata = metadata - 'ingress_hmac_verified'
   WHERE id = v_ingest.webhook_id;

  v_failed := false;
  BEGIN
    PERFORM *
      FROM henvalt.load_shopify_webhook_replay_job(v_claim.id, v_worker);
  EXCEPTION WHEN insufficient_privilege THEN
    v_failed := true;
  END;

  IF NOT v_failed THEN
    RAISE EXCEPTION 'REPLAY_LOADER_ACCEPTED_UNVERIFIED_INGRESS_ROW';
  END IF;

  UPDATE henvalt.webhook_events
     SET metadata = metadata || jsonb_build_object('ingress_hmac_verified', true),
         processing_status = 'PROCESSED',
         processed_at = now()
   WHERE id = v_ingest.webhook_id;

  SELECT * INTO v_loaded
    FROM henvalt.load_shopify_webhook_replay_job(v_claim.id, v_worker);

  IF v_loaded.webhook_processed IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'REPLAY_LOADER_DID_NOT_REPORT_PROCESSED_EVENT';
  END IF;

  IF NOT has_function_privilege('service_role', v_function, 'EXECUTE')
     OR has_function_privilege('anon', v_function, 'EXECUTE')
     OR has_function_privilege('authenticated', v_function, 'EXECUTE') THEN
    RAISE EXCEPTION 'REPLAY_LOADER_RPC_PRIVILEGES_NOT_RESTRICTED';
  END IF;

  RAISE NOTICE 'SHOPIFY_WEBHOOK_REPLAY_LOADER_ACCEPTANCE_PASSED';
END;
$replay_loader$;

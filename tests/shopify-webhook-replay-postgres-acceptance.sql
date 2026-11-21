\set ON_ERROR_STOP on

INSERT INTO henvalt.tenants (id, status)
VALUES ('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', 'ACTIVE')
ON CONFLICT (id) DO NOTHING;

DO $acceptance$
DECLARE
  v_first record;
  v_duplicate record;
  v_processed record;
  v_count integer;
  v_failed boolean := false;
  v_function text := 'henvalt.ingest_shopify_webhook_with_replay_job(uuid,text,text,text,text,jsonb,jsonb)';
BEGIN
  SELECT * INTO v_first
    FROM henvalt.ingest_shopify_webhook_with_replay_job(
      'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
      'shopify',
      'delivery-replay-001',
      'checkouts/update',
      'shopify:delivery-replay-001',
      '{"id":"checkout-001","test":true}'::jsonb,
      '{"correlation_id":"bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"}'::jsonb
    );

  IF v_first.webhook_id IS NULL
     OR v_first.is_duplicate IS NOT FALSE
     OR v_first.should_process IS NOT TRUE
     OR v_first.processing_status IS DISTINCT FROM 'PROCESSING'
     OR v_first.replay_job_id IS NULL
     OR v_first.replay_job_status IS DISTINCT FROM 'QUEUED' THEN
    RAISE EXCEPTION 'NEW_WEBHOOK_DID_NOT_ATOMICALLY_ENQUEUE_REPLAY_JOB';
  END IF;

  SELECT count(*) INTO v_count
    FROM henvalt.background_jobs
   WHERE tenant_id = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'
     AND job_type = 'process_shopify_webhook'
     AND idempotency_key = 'shopify-webhook-replay:' || v_first.webhook_id::text;

  IF v_count <> 1 THEN
    RAISE EXCEPTION 'EXPECTED_EXACTLY_ONE_REPLAY_JOB_GOT_%', v_count;
  END IF;

  SELECT * INTO v_duplicate
    FROM henvalt.ingest_shopify_webhook_with_replay_job(
      'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
      'shopify',
      'delivery-replay-001',
      'checkouts/update',
      'shopify:delivery-replay-001',
      '{"id":"checkout-001","test":true}'::jsonb,
      '{"correlation_id":"bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"}'::jsonb
    );

  IF v_duplicate.webhook_id IS DISTINCT FROM v_first.webhook_id
     OR v_duplicate.is_duplicate IS NOT TRUE
     OR v_duplicate.should_process IS NOT FALSE
     OR v_duplicate.replay_job_id IS DISTINCT FROM v_first.replay_job_id
     OR v_duplicate.replay_job_status IS DISTINCT FROM 'QUEUED' THEN
    RAISE EXCEPTION 'DUPLICATE_DID_NOT_RETURN_EXISTING_REPLAY_JOB';
  END IF;

  UPDATE henvalt.webhook_events
     SET processing_status = 'PROCESSED', processed_at = now()
   WHERE id = v_first.webhook_id;

  SELECT * INTO v_processed
    FROM henvalt.ingest_shopify_webhook_with_replay_job(
      'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
      'shopify',
      'delivery-replay-001',
      'checkouts/update',
      'shopify:delivery-replay-001',
      '{"id":"checkout-001","test":true}'::jsonb,
      '{"correlation_id":"bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"}'::jsonb
    );

  IF v_processed.webhook_id IS DISTINCT FROM v_first.webhook_id
     OR v_processed.processing_status IS DISTINCT FROM 'PROCESSED'
     OR v_processed.should_process IS NOT FALSE
     OR v_processed.replay_job_id IS NOT NULL THEN
    RAISE EXCEPTION 'PROCESSED_DUPLICATE_SHOULD_NOT_ENQUEUE_ANOTHER_JOB';
  END IF;

  IF NOT has_function_privilege('service_role', v_function, 'EXECUTE')
     OR has_function_privilege('anon', v_function, 'EXECUTE')
     OR has_function_privilege('authenticated', v_function, 'EXECUTE') THEN
    RAISE EXCEPTION 'REPLAY_INGEST_RPC_PRIVILEGES_NOT_RESTRICTED';
  END IF;

  RAISE NOTICE 'SHOPIFY_WEBHOOK_REPLAY_ENQUEUE_ACCEPTANCE_PASSED';
END;
$acceptance$;

CREATE OR REPLACE FUNCTION henvalt.test_fail_replay_job_insert()
RETURNS trigger
LANGUAGE plpgsql
AS $function$
BEGIN
  IF NEW.job_type = 'process_shopify_webhook' THEN
    RAISE EXCEPTION 'SIMULATED_REPLAY_QUEUE_UNAVAILABLE';
  END IF;
  RETURN NEW;
END;
$function$;

CREATE TRIGGER test_fail_replay_job_insert
BEFORE INSERT ON henvalt.background_jobs
FOR EACH ROW
EXECUTE FUNCTION henvalt.test_fail_replay_job_insert();

DO $atomicity$
DECLARE
  v_failed boolean := false;
  v_count integer;
BEGIN
  BEGIN
    PERFORM *
      FROM henvalt.ingest_shopify_webhook_with_replay_job(
        'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
        'shopify',
        'delivery-replay-rollback',
        'checkouts/update',
        'shopify:delivery-replay-rollback',
        '{"id":"checkout-rollback","test":true}'::jsonb,
        '{}'::jsonb
      );
  EXCEPTION WHEN OTHERS THEN
    v_failed := true;
  END;

  SELECT count(*) INTO v_count
    FROM henvalt.webhook_events
   WHERE tenant_id = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'
     AND source_event_id = 'delivery-replay-rollback';

  IF NOT v_failed OR v_count <> 0 THEN
    RAISE EXCEPTION 'WEBHOOK_ROW_WAS_NOT_ROLLED_BACK_WITH_FAILED_REPLAY_ENQUEUE';
  END IF;

  RAISE NOTICE 'SHOPIFY_WEBHOOK_REPLAY_ATOMICITY_ACCEPTANCE_PASSED';
END;
$atomicity$;

DROP TRIGGER test_fail_replay_job_insert ON henvalt.background_jobs;
DROP FUNCTION henvalt.test_fail_replay_job_insert();

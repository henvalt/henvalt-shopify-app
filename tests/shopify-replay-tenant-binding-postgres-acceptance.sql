\set ON_ERROR_STOP on
INSERT INTO henvalt.tenants(id,status) VALUES
 ('edededed-eded-4ded-8ded-edededededed','ACTIVE'),
 ('fefefefe-fefe-4efe-8efe-fefefefefefe','ACTIVE')
ON CONFLICT (id) DO NOTHING;

DO $tenant_binding$
DECLARE
  v_webhook_a uuid;
  v_webhook_b uuid;
  v_job uuid;
  v_claim record;
  v_rejected boolean;
BEGIN
  INSERT INTO henvalt.webhook_events(tenant_id,source,source_event_id,topic,idempotency_key,payload,metadata,processing_status)
  VALUES ('edededed-eded-4ded-8ded-edededededed','shopify','tenant-bind-a','checkouts/update','tenant-bind-a',
    '{"id":"tenant-a","test":true}'::jsonb,'{"ingress_hmac_verified":true}'::jsonb,'PROCESSING')
  RETURNING id INTO v_webhook_a;
  INSERT INTO henvalt.webhook_events(tenant_id,source,source_event_id,topic,idempotency_key,payload,metadata,processing_status)
  VALUES ('fefefefe-fefe-4efe-8efe-fefefefefefe','shopify','tenant-bind-b','checkouts/update','tenant-bind-b',
    '{"id":"tenant-b","test":true}'::jsonb,'{"ingress_hmac_verified":true}'::jsonb,'PROCESSING')
  RETURNING id INTO v_webhook_b;
  INSERT INTO henvalt.background_jobs(tenant_id,job_type,payload,status,attempts,max_attempts,idempotency_key)
  VALUES ('edededed-eded-4ded-8ded-edededededed','process_shopify_webhook',
    jsonb_build_object('webhook_id',v_webhook_a),'QUEUED',0,5,'tenant-bind-job-a')
  RETURNING id INTO v_job;

  SELECT * INTO v_claim FROM henvalt.claim_shopify_replay_job('tenant-binding-worker',60);
  IF v_claim.id IS DISTINCT FROM v_job OR v_claim.lease_id IS NULL THEN
    RAISE EXCEPTION 'TENANT_BINDING_FIXTURE_CLAIM_FAILED';
  END IF;

  v_rejected := false;
  BEGIN
    PERFORM henvalt.upsert_customer_fenced(
      v_job,'tenant-binding-worker',v_claim.lease_id,
      'fefefefe-fefe-4efe-8efe-fefefefefefe','foreign-customer','foreign@example.invalid',
      NULL,NULL,NULL,true,false,false,'{}'::jsonb
    );
  EXCEPTION WHEN insufficient_privilege THEN v_rejected := true;
  END;
  IF NOT v_rejected THEN RAISE EXCEPTION 'CROSS_TENANT_CUSTOMER_WRITE_WAS_ALLOWED'; END IF;

  v_rejected := false;
  BEGIN
    PERFORM henvalt.mark_webhook_failed_fenced(
      v_job,'tenant-binding-worker',v_claim.lease_id,v_webhook_b,'cross-tenant mutation'
    );
  EXCEPTION WHEN insufficient_privilege THEN v_rejected := true;
  END;
  IF NOT v_rejected THEN RAISE EXCEPTION 'CROSS_TENANT_WEBHOOK_STATE_WRITE_WAS_ALLOWED'; END IF;

  IF NOT EXISTS (SELECT 1 FROM henvalt.webhook_events WHERE id=v_webhook_b AND processing_status='PROCESSING') THEN
    RAISE EXCEPTION 'CROSS_TENANT_WEBHOOK_STATE_CHANGED';
  END IF;

  PERFORM henvalt.upsert_customer_fenced(
    v_job,'tenant-binding-worker',v_claim.lease_id,
    'edededed-eded-4ded-8ded-edededededed','local-customer','local@example.invalid',
    NULL,NULL,NULL,true,false,false,'{}'::jsonb
  );

  RAISE NOTICE 'SHOPIFY_REPLAY_TENANT_BINDING_ACCEPTANCE_PASSED';
END;
$tenant_binding$;

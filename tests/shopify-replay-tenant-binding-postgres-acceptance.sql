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
  v_customer_a uuid;
  v_customer_b uuid;
BEGIN
  INSERT INTO henvalt.customers(tenant_id,shopify_customer_id,email,email_consent)
  VALUES ('edededed-eded-4ded-8ded-edededededed','tenant-a-customer','a@example.invalid',true)
  RETURNING id INTO v_customer_a;
  INSERT INTO henvalt.customers(tenant_id,shopify_customer_id,email,email_consent)
  VALUES ('fefefefe-fefe-4efe-8efe-fefefefefefe','tenant-b-customer','b@example.invalid',true)
  RETURNING id INTO v_customer_b;
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

  v_rejected := false;
  BEGIN
    PERFORM henvalt.assert_shopify_replay_object_tenant(
      v_job,'tenant-binding-worker',v_claim.lease_id,
      'edededed-eded-4ded-8ded-edededededed','customers',v_customer_b
    );
  EXCEPTION WHEN insufficient_privilege THEN v_rejected := true;
  END;
  IF NOT v_rejected THEN RAISE EXCEPTION 'CROSS_TENANT_OBJECT_WRITE_GUARD_WAS_ALLOWED'; END IF;

  PERFORM henvalt.assert_shopify_replay_object_tenant(
    v_job,'tenant-binding-worker',v_claim.lease_id,
    'edededed-eded-4ded-8ded-edededededed','customers',v_customer_a
  );

  -- Exercise the positive authorization path without depending on a
  -- business-RPC fixture unrelated to the tenant guard itself.
  PERFORM henvalt.assert_shopify_replay_tenant_for_write(
    v_job,'tenant-binding-worker',v_claim.lease_id,
    'edededed-eded-4ded-8ded-edededededed'
  );
  PERFORM henvalt.assert_shopify_replay_webhook_for_write(
    v_job,'tenant-binding-worker',v_claim.lease_id,v_webhook_a
  );

  RAISE NOTICE 'SHOPIFY_REPLAY_TENANT_BINDING_ACCEPTANCE_PASSED';
END;
$tenant_binding$;

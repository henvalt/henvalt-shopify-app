-- Positive-path pixel attempt cost-state transitions on disposable PostgreSQL only.
-- No permit is minted and no provider or customer request is made.
BEGIN;
DO $test$
DECLARE
 v_tenant uuid:='00000000-0000-4000-8000-000000000001';
 v_connection uuid; v_customer uuid; v_provider text; v_app_key text;
 v_session uuid; v_inbox uuid; v_candidate uuid; v_opportunity uuid; v_attempt uuid;
 v_result jsonb; v_reservation_status text;
 v_source_delivery uuid; v_order_id uuid; v_attr_id uuid; v_attributed_order_id uuid; v_store_a uuid;
 v_provider_event_id text; v_provider_message_id text;
 v_policy_result jsonb; v_dashboard jsonb;
 v_order_body text; v_order_hmac text; v_shopify_order_id text;
 v_order_delivery_id text; v_order_event_id text;
 v_webhook_result record; v_order_projection jsonb;
 v_claim jsonb; v_lease_id uuid; v_retry_lease_id uuid; v_finish jsonb;
BEGIN
 SELECT id,app_key INTO v_connection,v_app_key FROM henvalt.shopify_connections
  WHERE tenant_id=v_tenant AND shop_domain='store-b.myshopify.com';
 SELECT id INTO v_customer FROM henvalt.shopify_customer_identity_v2
  WHERE tenant_id=v_tenant AND shopify_connection_id=v_connection
    AND external_customer_reference='12345';
 SELECT provider_account_key INTO v_provider FROM henvalt.shopify_mailer_provider_registry_v2
  WHERE tenant_id=v_tenant AND status='ACTIVE'
    AND email_unit_cost_amount=0.01 AND email_unit_cost_currency='USD'
  ORDER BY created_at LIMIT 1;
 IF v_connection IS NULL OR v_customer IS NULL OR v_provider IS NULL OR v_app_key IS NULL THEN
  RAISE EXCEPTION 'Pixel outcome fixture dependencies missing';
 END IF;

 INSERT INTO henvalt.shopify_pixel_event_inbox_v2(
  tenant_id,shopify_connection_id,source_event_id,event_type,event_digest,
  occurred_at,analytics_processing_allowed,marketing_allowed,client_reference,
  customer_reference,payload,status,processed_at
 ) VALUES(v_tenant,v_connection,'pixel-outcome-'||gen_random_uuid()::text,
  'product_added_to_cart',encode(extensions.digest(convert_to(gen_random_uuid()::text,'UTF8'),'sha256'),'hex'),
  now()-interval '1 hour',true,false,'outcome-browser','12345',
  '{"product":{"id":"outcome-product"}}'::jsonb,'PROCESSED',now())
 RETURNING id INTO v_inbox;
 INSERT INTO henvalt.shopify_session_identity_v2(
  tenant_id,shopify_connection_id,session_reference,customer_identity_id
 ) VALUES(v_tenant,v_connection,'outcome-session-'||gen_random_uuid()::text,v_customer)
 RETURNING id INTO v_session;
 INSERT INTO henvalt.shopify_pixel_recovery_candidate_v2(
  tenant_id,shopify_connection_id,candidate_type,session_identity_id,customer_identity_id,
  source_inbox_event_id,product_key,product_context,last_activity_at,eligible_after,status,idempotency_key
 ) VALUES(v_tenant,v_connection,'ABANDONED_CART',v_session,v_customer,v_inbox,
  'outcome-product','{"product_id":"outcome-product"}'::jsonb,now()-interval '1 hour',
  now()-interval '30 minutes','PROMOTED','outcome-candidate-'||gen_random_uuid()::text)
 RETURNING id INTO v_candidate;
 INSERT INTO henvalt.shopify_recovery_opportunity_v2(
  tenant_id,shopify_connection_id,app_key,candidate_id,checkout_identity_id,customer_identity_id,
  source_delivery_id,pixel_candidate_id,opportunity_type,status,idempotency_key
 ) VALUES(v_tenant,v_connection,v_app_key,NULL,NULL,v_customer,NULL,v_candidate,
  'ABANDONED_CART','REVIEW_REQUIRED','outcome-opportunity-'||gen_random_uuid()::text)
 RETURNING id INTO v_opportunity;

 -- The shared n8n lease queue exposes this pixel opportunity as opaque work,
 -- without converting REVIEW_REQUIRED into delivery authorization.
 PERFORM pg_catalog.set_config('request.jwt.claim.role','service_role',true);
 v_claim:=henvalt.claim_shopify_recovery_work_v2('test-worker-a',10,120);
 IF v_claim->>'accepted'<>'true'
   OR v_claim->>'delivery_authorized'<>'false'
   OR v_claim->>'provider_called'<>'false'
   OR v_claim->>'recipient_pii_returned'<>'false'
   OR NOT EXISTS(
     SELECT 1 FROM jsonb_array_elements(v_claim->'items') AS x(item)
     WHERE x.item->>'work_type'='PIXEL_OPPORTUNITY'
       AND x.item->>'work_id'=v_opportunity::text
       AND x.item->>'tenant_id'=v_tenant::text
       AND x.item->>'shopify_connection_id'=v_connection::text
       AND x.item->>'intervention_id' IS NULL
   ) THEN
  RAISE EXCEPTION 'Pixel opportunity was not safely exposed by the exact-store work lease: %',v_claim;
 END IF;
 SELECT (x.item->>'lease_id')::uuid INTO v_lease_id
 FROM jsonb_array_elements(v_claim->'items') AS x(item)
 WHERE x.item->>'work_id'=v_opportunity::text;
 IF v_lease_id IS NULL THEN
  RAISE EXCEPTION 'Pixel work lease did not return its opaque lease ID';
 END IF;
 v_claim:=henvalt.claim_shopify_recovery_work_v2('test-worker-b',10,120);
 IF EXISTS(
   SELECT 1 FROM jsonb_array_elements(v_claim->'items') AS x(item)
   WHERE x.item->>'work_id'=v_opportunity::text
 ) THEN
  RAISE EXCEPTION 'Concurrent worker received an already leased opportunity: %',v_claim;
 END IF;
 v_finish:=henvalt.finish_shopify_recovery_work_claim_v2(
  v_lease_id,'test-worker-a','DEFERRED',interval '0 seconds'
 );
 IF v_finish->>'finished'<>'true' OR v_finish->>'outcome'<>'DEFERRED' THEN
  RAISE EXCEPTION 'Pixel work lease could not be safely deferred: %',v_finish;
 END IF;
 v_claim:=henvalt.claim_shopify_recovery_work_v2('test-worker-b',10,120);
 SELECT (x.item->>'lease_id')::uuid INTO v_retry_lease_id
 FROM jsonb_array_elements(v_claim->'items') AS x(item)
 WHERE x.item->>'work_id'=v_opportunity::text;
 IF v_retry_lease_id IS NULL OR v_retry_lease_id=v_lease_id THEN
  RAISE EXCEPTION 'Deferred work was not reclaimed with a fresh lease identity: %',v_claim;
 END IF;
 v_finish:=henvalt.finish_shopify_recovery_work_claim_v2(
  v_lease_id,'test-worker-a','HANDOFF_ACCEPTED',interval '1 hour'
 );
 IF v_finish->>'finished'<>'false' OR v_finish->>'code'<>'LEASE_NOT_ACTIVE' THEN
  RAISE EXCEPTION 'Stale worker was able to complete a reclaimed lease: %',v_finish;
 END IF;
 v_finish:=henvalt.finish_shopify_recovery_work_claim_v2(
  v_retry_lease_id,'test-worker-b','HANDOFF_ACCEPTED',interval '1 hour'
 );
 IF v_finish->>'finished'<>'true' OR v_finish->>'outcome'<>'HANDOFF_ACCEPTED' THEN
  RAISE EXCEPTION 'Current worker could not complete its lease: %',v_finish;
 END IF;
 v_claim:=henvalt.claim_shopify_recovery_work_v2('test-worker-c',10,120);
 IF EXISTS(
   SELECT 1 FROM jsonb_array_elements(v_claim->'items') AS x(item)
   WHERE x.item->>'work_id'=v_opportunity::text
 ) THEN
  RAISE EXCEPTION 'Completed pixel work was claimed again: %',v_claim;
 END IF;

 INSERT INTO henvalt.shopify_pixel_send_attempts_v2(
  tenant_id,shopify_connection_id,opportunity_id,pixel_candidate_id,customer_identity_id,
  provider_account_key,idempotency_key,status
 ) VALUES(v_tenant,v_connection,v_opportunity,v_candidate,v_customer,v_provider,
  'outcome-attempt-'||gen_random_uuid()::text,'AUTHORIZED')
 RETURNING id INTO v_attempt;

 SELECT status INTO v_reservation_status FROM henvalt.shopify_pixel_delivery_cost_reservations_v2
  WHERE pixel_send_attempt_id=v_attempt;
 IF v_reservation_status IS DISTINCT FROM 'RESERVED' THEN
  RAISE EXCEPTION 'Authorized pixel attempt did not reserve provider cost: %',v_reservation_status;
 END IF;

 PERFORM pg_catalog.set_config('request.jwt.claim.role','service_role',true);
 v_result:=henvalt.record_shopify_pixel_send_attempt_result_v2(v_attempt,'AMBIGUOUS',NULL);
 IF v_result->>'recorded'<>'true' OR v_result->>'provider_cost_state'<>'RESERVED' THEN
  RAISE EXCEPTION 'Ambiguous pixel outcome was not retained: %',v_result;
 END IF;
 SELECT status INTO v_reservation_status FROM henvalt.shopify_pixel_delivery_cost_reservations_v2
  WHERE pixel_send_attempt_id=v_attempt;
 IF v_reservation_status IS DISTINCT FROM 'RESERVED' THEN
  RAISE EXCEPTION 'Ambiguous pixel attempt released cost reservation';
 END IF;
 v_result:=henvalt.record_shopify_pixel_send_attempt_result_v2(v_attempt,'FAILED',NULL);
 IF v_result->>'recorded'<>'false' OR v_result->>'code'<>'ATTEMPT_ALREADY_FINALIZED' THEN
  RAISE EXCEPTION 'Ambiguous attempt was incorrectly downgraded to failed: %',v_result;
 END IF;
 SELECT status INTO v_reservation_status FROM henvalt.shopify_pixel_delivery_cost_reservations_v2
  WHERE pixel_send_attempt_id=v_attempt;
 IF v_reservation_status IS DISTINCT FROM 'RESERVED' THEN
  RAISE EXCEPTION 'Rejected ambiguous-to-failed transition released cost reservation';
 END IF;

 v_result:=henvalt.record_shopify_pixel_send_attempt_result_v2(v_attempt,'SUBMITTED','synthetic-provider-message-id');
 IF v_result->>'recorded'<>'true' OR v_result->>'provider_cost_state'<>'SETTLED' THEN
  RAISE EXCEPTION 'Confirmed provider acceptance did not settle cost: %',v_result;
 END IF;
 SELECT status INTO v_reservation_status FROM henvalt.shopify_pixel_delivery_cost_reservations_v2
  WHERE pixel_send_attempt_id=v_attempt;
 IF v_reservation_status IS DISTINCT FROM 'SETTLED' THEN
  RAISE EXCEPTION 'Submitted pixel attempt did not settle reservation';
 END IF;
 v_result:=henvalt.record_shopify_pixel_send_attempt_result_v2(v_attempt,'FAILED',NULL);
 IF v_result->>'recorded'<>'false' OR v_result->>'code'<>'ATTEMPT_ALREADY_FINALIZED' THEN
  RAISE EXCEPTION 'Finalized submitted attempt accepted an invalid transition: %',v_result;
 END IF;

 -- A separate failed attempt must release only its own reservation.
 INSERT INTO henvalt.shopify_pixel_event_inbox_v2(
  tenant_id,shopify_connection_id,source_event_id,event_type,event_digest,
  occurred_at,analytics_processing_allowed,marketing_allowed,client_reference,
  customer_reference,payload,status,processed_at
 ) VALUES(v_tenant,v_connection,'pixel-outcome-fail-'||gen_random_uuid()::text,
  'product_added_to_cart',encode(extensions.digest(convert_to(gen_random_uuid()::text,'UTF8'),'sha256'),'hex'),
  now()-interval '1 hour',true,false,'outcome-browser','12345',
  '{"product":{"id":"outcome-fail-product"}}'::jsonb,'PROCESSED',now())
 RETURNING id INTO v_inbox;
 INSERT INTO henvalt.shopify_session_identity_v2(
  tenant_id,shopify_connection_id,session_reference,customer_identity_id
 ) VALUES(v_tenant,v_connection,'outcome-fail-session-'||gen_random_uuid()::text,v_customer)
 RETURNING id INTO v_session;
 INSERT INTO henvalt.shopify_pixel_recovery_candidate_v2(
  tenant_id,shopify_connection_id,candidate_type,session_identity_id,customer_identity_id,
  source_inbox_event_id,product_key,product_context,last_activity_at,eligible_after,status,idempotency_key
 ) VALUES(v_tenant,v_connection,'ABANDONED_CART',v_session,v_customer,v_inbox,
  'outcome-fail-product','{"product_id":"outcome-fail-product"}'::jsonb,now()-interval '1 hour',
  now()-interval '30 minutes','PROMOTED','outcome-fail-candidate-'||gen_random_uuid()::text)
 RETURNING id INTO v_candidate;
 INSERT INTO henvalt.shopify_recovery_opportunity_v2(
  tenant_id,shopify_connection_id,app_key,candidate_id,checkout_identity_id,customer_identity_id,
  source_delivery_id,pixel_candidate_id,opportunity_type,status,idempotency_key
 ) VALUES(v_tenant,v_connection,v_app_key,NULL,NULL,v_customer,NULL,v_candidate,
  'ABANDONED_CART','REVIEW_REQUIRED','outcome-fail-opportunity-'||gen_random_uuid()::text)
 RETURNING id INTO v_opportunity;
 INSERT INTO henvalt.shopify_pixel_send_attempts_v2(
  tenant_id,shopify_connection_id,opportunity_id,pixel_candidate_id,customer_identity_id,
  provider_account_key,idempotency_key,status
 ) VALUES(v_tenant,v_connection,v_opportunity,v_candidate,v_customer,v_provider,
  'outcome-fail-attempt-'||gen_random_uuid()::text,'AUTHORIZED')
 RETURNING id INTO v_attempt;
 v_result:=henvalt.record_shopify_pixel_send_attempt_result_v2(v_attempt,'FAILED',NULL);
 IF v_result->>'recorded'<>'true' OR v_result->>'provider_cost_state'<>'RELEASED' THEN
  RAISE EXCEPTION 'Failed pixel attempt did not release its reservation: %',v_result;
 END IF;
 SELECT status INTO v_reservation_status FROM henvalt.shopify_pixel_delivery_cost_reservations_v2
  WHERE pixel_send_attempt_id=v_attempt;
 IF v_reservation_status IS DISTINCT FROM 'RELEASED' THEN
  RAISE EXCEPTION 'Failed pixel attempt reservation is not released';
 END IF;

 -- A signed MailerSend activity event can resolve an ambiguous pixel attempt
 -- only after its provider message reference is retained on that attempt.
 INSERT INTO henvalt.shopify_pixel_event_inbox_v2(
  tenant_id,shopify_connection_id,source_event_id,event_type,event_digest,
  occurred_at,analytics_processing_allowed,marketing_allowed,client_reference,
  customer_reference,payload,status,processed_at
 ) VALUES(v_tenant,v_connection,'pixel-outcome-event-'||gen_random_uuid()::text,
  'product_added_to_cart',encode(extensions.digest(convert_to(gen_random_uuid()::text,'UTF8'),'sha256'),'hex'),
  now()-interval '1 hour',true,false,'outcome-browser','12345',
  '{"product":{"id":"outcome-event-product"}}'::jsonb,'PROCESSED',now())
 RETURNING id INTO v_inbox;
 INSERT INTO henvalt.shopify_session_identity_v2(
  tenant_id,shopify_connection_id,session_reference,customer_identity_id
 ) VALUES(v_tenant,v_connection,'outcome-event-session-'||gen_random_uuid()::text,v_customer)
 RETURNING id INTO v_session;
 INSERT INTO henvalt.shopify_pixel_recovery_candidate_v2(
  tenant_id,shopify_connection_id,candidate_type,session_identity_id,customer_identity_id,
  source_inbox_event_id,product_key,product_context,last_activity_at,eligible_after,status,idempotency_key
 ) VALUES(v_tenant,v_connection,'ABANDONED_CART',v_session,v_customer,v_inbox,
  'outcome-event-product','{"product_id":"outcome-event-product"}'::jsonb,now()-interval '1 hour',
  now()-interval '30 minutes','PROMOTED','outcome-event-candidate-'||gen_random_uuid()::text)
 RETURNING id INTO v_candidate;
 INSERT INTO henvalt.shopify_recovery_opportunity_v2(
  tenant_id,shopify_connection_id,app_key,candidate_id,checkout_identity_id,customer_identity_id,
  source_delivery_id,pixel_candidate_id,opportunity_type,status,idempotency_key
 ) VALUES(v_tenant,v_connection,v_app_key,NULL,NULL,v_customer,NULL,v_candidate,
  'ABANDONED_CART','REVIEW_REQUIRED','outcome-event-opportunity-'||gen_random_uuid()::text)
 RETURNING id INTO v_opportunity;
 INSERT INTO henvalt.shopify_pixel_send_attempts_v2(
  tenant_id,shopify_connection_id,opportunity_id,pixel_candidate_id,customer_identity_id,
  provider_account_key,idempotency_key,status
 ) VALUES(v_tenant,v_connection,v_opportunity,v_candidate,v_customer,v_provider,
  'outcome-event-attempt-'||gen_random_uuid()::text,'AUTHORIZED')
 RETURNING id INTO v_attempt;
 v_result:=henvalt.record_shopify_pixel_send_attempt_result_v2(
  v_attempt,'AMBIGUOUS','synthetic-provider-message-id-2'
 );
 IF v_result->>'recorded'<>'true' OR v_result->>'provider_cost_state'<>'RESERVED' THEN
  RAISE EXCEPTION 'Ambiguous attempt did not retain provider reference and reservation: %',v_result;
 END IF;
 INSERT INTO henvalt.shopify_mailer_provider_events_v2(
  provider_account_key,provider_event_id,provider_message_id,event_type,
  body_sha256,processing_status
 ) VALUES(v_provider,'pixel-provider-event-'||gen_random_uuid()::text,
  'synthetic-provider-message-id-2','activity.delivered',repeat('a',64),'UNMATCHED');
 v_result:=henvalt.reconcile_mailersend_pixel_provider_event_v2(
  v_provider,(SELECT provider_event_id FROM henvalt.shopify_mailer_provider_events_v2
   WHERE provider_account_key=v_provider AND provider_message_id='synthetic-provider-message-id-2')
 );
 IF v_result->>'accepted'<>'true' OR v_result->>'pixel_attempt_reconciled'<>'true'
   OR v_result->>'provider_cost_state'<>'SETTLED' THEN
  RAISE EXCEPTION 'Verified provider event did not reconcile ambiguous pixel attempt: %',v_result;
 END IF;
 IF NOT EXISTS(SELECT 1 FROM henvalt.shopify_pixel_send_attempts_v2
   WHERE id=v_attempt AND status='SUBMITTED'
     AND provider_message_reference='synthetic-provider-message-id-2')
   OR NOT EXISTS(SELECT 1 FROM henvalt.shopify_pixel_delivery_cost_reservations_v2
     WHERE pixel_send_attempt_id=v_attempt AND status='SETTLED')
   OR NOT EXISTS(SELECT 1 FROM henvalt.shopify_mailer_provider_events_v2
     WHERE provider_account_key=v_provider AND provider_message_id='synthetic-provider-message-id-2'
       AND pixel_send_attempt_id=v_attempt AND processing_status='PROCESSED') THEN
  RAISE EXCEPTION 'Provider event failed to durably reconcile pixel send and cost';
 END IF;
 v_result:=henvalt.reconcile_mailersend_pixel_provider_event_v2(
  v_provider,(SELECT provider_event_id FROM henvalt.shopify_mailer_provider_events_v2
   WHERE provider_account_key=v_provider AND provider_message_id='synthetic-provider-message-id-2')
 );
 IF v_result->>'accepted'<>'true' OR v_result->>'status'<>'DUPLICATE' THEN
  RAISE EXCEPTION 'Duplicate provider event reconciliation was not idempotent: %',v_result;
 END IF;
 INSERT INTO henvalt.shopify_mailer_provider_events_v2(
  provider_account_key,provider_event_id,provider_message_id,event_type,
  body_sha256,processing_status
 ) VALUES(v_provider,'pixel-provider-unsubscribe-'||gen_random_uuid()::text,
  'synthetic-provider-message-id-2','activity.unsubscribed',repeat('b',64),'UNMATCHED');
 v_result:=henvalt.reconcile_mailersend_pixel_provider_event_v2(
  v_provider,(SELECT provider_event_id FROM henvalt.shopify_mailer_provider_events_v2
   WHERE provider_account_key=v_provider AND provider_message_id='synthetic-provider-message-id-2'
     AND event_type='activity.unsubscribed')
 );
 IF v_result->>'accepted'<>'true' OR v_result->>'pixel_attempt_reconciled'<>'true'
   OR v_result->>'suppression_applied'<>'true' THEN
  RAISE EXCEPTION 'Verified pixel unsubscribe event did not create exact-store suppression: %',v_result;
 END IF;
 IF NOT EXISTS(SELECT 1 FROM henvalt.shopify_delivery_suppressions_v2
   WHERE tenant_id=v_tenant AND shopify_connection_id=v_connection
     AND customer_identity_id=v_customer AND source_pixel_send_attempt_id=v_attempt
     AND source_send_attempt_id IS NULL AND suppression_type='UNSUBSCRIBED' AND active IS TRUE) THEN
  RAISE EXCEPTION 'Pixel unsubscribe suppression did not retain exact-store attempt lineage';
 END IF;
 -- This isolated lifecycle fixture needs room for its additional synthetic attempt;
 -- the merchant-wide cap itself is covered by the separate concurrent-cap harness.
 UPDATE henvalt.billing_accounts SET monthly_email_limit=100 WHERE tenant_id=v_tenant;

 -- A crashed worker's stale AUTHORIZED attempt is marked AMBIGUOUS and remains reserved.
 INSERT INTO henvalt.shopify_pixel_event_inbox_v2(
  tenant_id,shopify_connection_id,source_event_id,event_type,event_digest,
  occurred_at,analytics_processing_allowed,marketing_allowed,client_reference,
  customer_reference,payload,status,processed_at
 ) VALUES(v_tenant,v_connection,'pixel-stale-event-'||gen_random_uuid()::text,
  'product_added_to_cart',encode(extensions.digest(convert_to(gen_random_uuid()::text,'UTF8'),'sha256'),'hex'),
  now()-interval '1 hour',true,false,'outcome-browser','12345',
  '{"product":{"id":"outcome-stale-product"}}'::jsonb,'PROCESSED',now())
 RETURNING id INTO v_inbox;
 INSERT INTO henvalt.shopify_session_identity_v2(
  tenant_id,shopify_connection_id,session_reference,customer_identity_id
 ) VALUES(v_tenant,v_connection,'outcome-stale-session-'||gen_random_uuid()::text,v_customer)
 RETURNING id INTO v_session;
 INSERT INTO henvalt.shopify_pixel_recovery_candidate_v2(
  tenant_id,shopify_connection_id,candidate_type,session_identity_id,customer_identity_id,
  source_inbox_event_id,product_key,product_context,last_activity_at,eligible_after,status,idempotency_key
 ) VALUES(v_tenant,v_connection,'ABANDONED_CART',v_session,v_customer,v_inbox,
  'outcome-stale-product','{"product_id":"outcome-stale-product"}'::jsonb,now()-interval '1 hour',
  now()-interval '30 minutes','PROMOTED','outcome-stale-candidate-'||gen_random_uuid()::text)
 RETURNING id INTO v_candidate;
 INSERT INTO henvalt.shopify_recovery_opportunity_v2(
  tenant_id,shopify_connection_id,app_key,candidate_id,checkout_identity_id,customer_identity_id,
  source_delivery_id,pixel_candidate_id,opportunity_type,status,idempotency_key
 ) VALUES(v_tenant,v_connection,v_app_key,NULL,NULL,v_customer,NULL,v_candidate,
  'ABANDONED_CART','REVIEW_REQUIRED','outcome-stale-opportunity-'||gen_random_uuid()::text)
 RETURNING id INTO v_opportunity;
 INSERT INTO henvalt.shopify_pixel_send_attempts_v2(
  tenant_id,shopify_connection_id,opportunity_id,pixel_candidate_id,customer_identity_id,
  provider_account_key,idempotency_key,status
 ) VALUES(v_tenant,v_connection,v_opportunity,v_candidate,v_customer,v_provider,
  'outcome-stale-attempt-'||gen_random_uuid()::text,'AUTHORIZED')
 RETURNING id INTO v_attempt;
 UPDATE henvalt.shopify_pixel_send_attempts_v2
 SET created_at=pg_catalog.now()-interval '5 minutes' WHERE id=v_attempt;
 v_result:=henvalt.mark_stale_shopify_pixel_send_attempts_ambiguous_v2(
  pg_catalog.now()-interval '3 minutes',10
 );
 IF v_result->>'accepted'<>'true' OR (v_result->>'marked_ambiguous')::integer<>1
   OR v_result->>'automatic_retry_performed'<>'false'
   OR v_result->>'provider_cost_reservation_released'<>'false' THEN
  RAISE EXCEPTION 'Stale worker attempt was not safely marked ambiguous: %',v_result;
 END IF;
 IF NOT EXISTS(SELECT 1 FROM henvalt.shopify_pixel_send_attempts_v2
   WHERE id=v_attempt AND status='AMBIGUOUS')
   OR NOT EXISTS(SELECT 1 FROM henvalt.shopify_pixel_delivery_cost_reservations_v2
     WHERE pixel_send_attempt_id=v_attempt AND status='RESERVED') THEN
  RAISE EXCEPTION 'Stale worker reconciliation released or lost its cost reservation';
 END IF;
 v_result:=henvalt.record_shopify_pixel_send_attempt_result_v2(v_attempt,'FAILED',NULL);
 IF v_result->>'recorded'<>'false' OR v_result->>'code'<>'ATTEMPT_ALREADY_FINALIZED' THEN
  RAISE EXCEPTION 'Stale ambiguous attempt could be downgraded to failed: %',v_result;
 END IF;

 -- End-to-end pixel recovery attribution: provider touch first, then a paid
 -- same-store/customer order. Sent alone is insufficient when delivery is required.

 INSERT INTO henvalt.shopify_pixel_event_inbox_v2(
  tenant_id,shopify_connection_id,source_event_id,event_type,event_digest,
  occurred_at,analytics_processing_allowed,marketing_allowed,client_reference,
  customer_reference,payload,status,processed_at
 ) VALUES(v_tenant,v_connection,'pixel-attribution-'||gen_random_uuid()::text,
  'product_added_to_cart',encode(extensions.digest(convert_to(gen_random_uuid()::text,'UTF8'),'sha256'),'hex'),
  now()-interval '2 hours',true,false,'attribution-browser','12345',
  '{"product":{"id":"attribution-product"}}'::jsonb,'PROCESSED',now())
 RETURNING id INTO v_inbox;
 INSERT INTO henvalt.shopify_session_identity_v2(
  tenant_id,shopify_connection_id,session_reference,customer_identity_id
 ) VALUES(v_tenant,v_connection,'attribution-session-'||gen_random_uuid()::text,v_customer)
 RETURNING id INTO v_session;
 INSERT INTO henvalt.shopify_pixel_recovery_candidate_v2(
  tenant_id,shopify_connection_id,candidate_type,session_identity_id,customer_identity_id,
  source_inbox_event_id,product_key,product_context,last_activity_at,eligible_after,status,idempotency_key
 ) VALUES(v_tenant,v_connection,'ABANDONED_CART',v_session,v_customer,v_inbox,
  'attribution-product','{"product_id":"attribution-product"}'::jsonb,now()-interval '2 hours',
  now()-interval '1 hour','PROMOTED','attribution-candidate-'||gen_random_uuid()::text)
 RETURNING id INTO v_candidate;
 INSERT INTO henvalt.shopify_recovery_opportunity_v2(
  tenant_id,shopify_connection_id,app_key,candidate_id,checkout_identity_id,customer_identity_id,
  source_delivery_id,pixel_candidate_id,opportunity_type,status,idempotency_key
 ) VALUES(v_tenant,v_connection,v_app_key,NULL,NULL,v_customer,NULL,v_candidate,
  'ABANDONED_CART','REVIEW_REQUIRED','attribution-opportunity-'||gen_random_uuid()::text)
 RETURNING id INTO v_opportunity;
 INSERT INTO henvalt.shopify_pixel_send_attempts_v2(
  tenant_id,shopify_connection_id,opportunity_id,pixel_candidate_id,customer_identity_id,
  provider_account_key,idempotency_key,status
 ) VALUES(v_tenant,v_connection,v_opportunity,v_candidate,v_customer,v_provider,
  'attribution-attempt-'||gen_random_uuid()::text,'AUTHORIZED')
 RETURNING id INTO v_attempt;

 v_policy_result:=henvalt.set_shopify_recovery_attribution_policy_v2(
  v_connection,true,72,'LAST_ELIGIBLE_TOUCH','SHOPIFY_TOTAL_PRICE',true
 );
 IF v_policy_result->>'accepted'<>'true' THEN
  RAISE EXCEPTION 'Pixel attribution policy fixture rejected: %',v_policy_result;
 END IF;
 v_result:=henvalt.record_shopify_pixel_send_attempt_result_v2(
  v_attempt,'SUBMITTED','synthetic-pixel-attribution-message'
 );
 IF v_result->>'recorded'<>'true' THEN
  RAISE EXCEPTION 'Pixel attribution attempt could not be marked submitted: %',v_result;
 END IF;

 v_provider_event_id:='pixel-attribution-sent-'||gen_random_uuid()::text;
 v_provider_message_id:='synthetic-pixel-attribution-message';
 INSERT INTO henvalt.shopify_mailer_provider_events_v2(
  provider_account_key,provider_event_id,provider_message_id,event_type,
  occurred_at,body_sha256,processing_status
 ) VALUES(v_provider,v_provider_event_id,v_provider_message_id,'activity.sent',
  now()-interval '1 minute',repeat('c',64),'UNMATCHED');
 v_result:=henvalt.reconcile_mailersend_pixel_provider_event_v2(v_provider,v_provider_event_id);
 IF v_result->>'accepted'<>'true' OR v_result->>'pixel_attempt_reconciled'<>'true' THEN
  RAISE EXCEPTION 'Signed provider sent event did not reconcile: %',v_result;
 END IF;

 -- Drive the conversion through the real signed Shopify webhook receipt
 -- and exact-store order projector, not a direct table insert.
 v_shopify_order_id:=(1000000000000000+floor(random()*999999999)::bigint)::text;
 v_order_delivery_id:='pixel-attribution-order-delivery-'||gen_random_uuid()::text;
 v_order_event_id:='pixel-attribution-order-event-'||gen_random_uuid()::text;
 v_order_body:=jsonb_build_object(
  'shop_id','2002','id',v_shopify_order_id::bigint,
  'customer',jsonb_build_object('id',12345),
  'total_price','125.50','currency','USD','financial_status','paid',
  'created_at',to_char(now(),'YYYY-MM-DD"T"HH24:MI:SS"Z"')
 )::text;
 v_order_hmac:=encode(extensions.hmac(convert_to(v_order_body,'UTF8'),
  convert_to('synthetic-test-secret-never-used-in-production','UTF8'),'sha256'),'base64');
 SELECT * INTO v_webhook_result FROM henvalt.accept_shopify_webhook_v2(
  repeat('c',64),v_order_hmac,encode(convert_to(v_order_body,'UTF8'),'base64'),
  'store-b.myshopify.com','orders/create',v_order_delivery_id,v_order_event_id
 );
 IF v_webhook_result.accepted IS DISTINCT FROM true THEN
  RAISE EXCEPTION 'Signed Store B paid order receipt was rejected: %',row_to_json(v_webhook_result);
 END IF;
 v_order_projection:=henvalt.project_verified_shopify_order_v2(
  repeat('c',64),v_order_delivery_id,encode(convert_to(v_order_body,'UTF8'),'base64')
 );
 IF v_order_projection->>'accepted'<>'true'
   OR v_order_projection->>'checkout_match_status'<>'NO_CHECKOUT_TOKEN' THEN
  RAISE EXCEPTION 'Exact-store order projection did not preserve no-checkout lineage: %',v_order_projection;
 END IF;
 SELECT id INTO v_source_delivery FROM henvalt.shopify_webhook_deliveries
  WHERE connection_id=v_connection AND shopify_delivery_id=v_order_delivery_id;
 SELECT id INTO v_order_id FROM henvalt.shopify_order_identity_v2
  WHERE shopify_connection_id=v_connection AND shopify_order_id=v_shopify_order_id;
 IF v_source_delivery IS NULL OR v_order_id IS NULL THEN
  RAISE EXCEPTION 'Verified order projection did not create its exact-store order and receipt';
 END IF;

 IF EXISTS(SELECT 1 FROM henvalt.shopify_recovery_attributions_v2
   WHERE order_identity_id=v_order_id) THEN
  RAISE EXCEPTION 'Provider sent event alone incorrectly satisfied delivery-confirmed attribution';
 END IF;

 v_provider_event_id:='pixel-attribution-delivered-'||gen_random_uuid()::text;
 INSERT INTO henvalt.shopify_mailer_provider_events_v2(
  provider_account_key,provider_event_id,provider_message_id,event_type,
  occurred_at,body_sha256,processing_status
 ) VALUES(v_provider,v_provider_event_id,v_provider_message_id,'activity.delivered',
  now()-interval '30 seconds',repeat('d',64),'UNMATCHED');
 v_result:=henvalt.reconcile_mailersend_pixel_provider_event_v2(v_provider,v_provider_event_id);
 IF v_result->>'accepted'<>'true' OR v_result->>'pixel_attempt_reconciled'<>'true' THEN
  RAISE EXCEPTION 'Signed provider delivered event did not reconcile: %',v_result;
 END IF;

 SELECT id INTO v_attr_id
 FROM henvalt.shopify_recovery_attributions_v2
 WHERE tenant_id=v_tenant AND shopify_connection_id=v_connection
   AND order_identity_id=v_order_id;
 IF v_attr_id IS NULL THEN
  RAISE EXCEPTION 'Paid pixel recovery order was not attributed after delivered evidence';
 END IF;
 v_attributed_order_id:=v_order_id;
 IF NOT EXISTS(
  SELECT 1 FROM henvalt.shopify_recovery_attributions_v2
  WHERE id=v_attr_id AND status='CONFIRMED'
    AND checkout_identity_id IS NULL AND send_attempt_id IS NULL
    AND pixel_send_attempt_id=v_attempt
    AND gross_recovered_amount=125.50 AND net_recovered_amount=125.50
    AND currency='USD'
 ) THEN
  RAISE EXCEPTION 'Pixel attribution source shape or confirmed revenue fields are incorrect';
 END IF;
 IF NOT EXISTS(
  SELECT 1 FROM henvalt.shopify_recovery_opportunity_v2
  WHERE id=v_opportunity AND status='CONVERTED'
 ) THEN
  RAISE EXCEPTION 'Attributed pixel opportunity was not marked converted';
 END IF;

 -- A second paid order cannot reuse the same recovery opportunity/touch.
 INSERT INTO henvalt.shopify_order_identity_v2(
  tenant_id,shopify_connection_id,shopify_order_id,checkout_token,
  customer_identity_id,total_value,currency,financial_status,ordered_at,
  source_delivery_id,checkout_match_status,updated_at
 ) VALUES(v_tenant,v_connection,'pixel-attribution-second-order-'||gen_random_uuid()::text,
  NULL,v_customer,20.00,'USD','paid',now(),v_source_delivery,'NO_CHECKOUT_TOKEN',now())
 RETURNING id INTO v_order_id;
 IF EXISTS(SELECT 1 FROM henvalt.shopify_recovery_attributions_v2
   WHERE order_identity_id=v_order_id) THEN
  RAISE EXCEPTION 'One pixel opportunity was attributed to more than one order';
 END IF;


 -- The V2 dashboard reads only this immutable store scope and the confirmed
 -- attribution ledger; it does not blend legacy tenant-wide revenue.
 v_dashboard:=henvalt.control_plane_dashboard_summary_v2(
  v_connection,now()-interval '1 day',now()
 );
 IF v_dashboard->>'linked'<>'true'
   OR (v_dashboard->'metrics'->>'recoveredOrders')::integer<>1
   OR (v_dashboard->'metrics'->>'revenueRecovered')::numeric<>125.50
   OR (v_dashboard->'metrics'->>'messagesSent')::integer<1 THEN
  RAISE EXCEPTION 'V2 dashboard did not report exact-store confirmed pixel recovery: %',v_dashboard;
 END IF;
 v_store_a:=gen_random_uuid();
 INSERT INTO henvalt.shopify_connections(
  id,tenant_id,shop_domain,shopify_shop_id,active,app_key
 ) VALUES(v_store_a,v_tenant,
  'dashboard-isolation-'||left(replace(gen_random_uuid()::text,'-',''),12)||'.myshopify.com',
  'dashboard-isolation-shop-'||left(replace(gen_random_uuid()::text,'-',''),12),
  true,v_app_key);
 v_dashboard:=henvalt.control_plane_dashboard_summary_v2(
  v_store_a,now()-interval '1 day',now()
 );
 IF v_dashboard->>'linked'<>'true'
   OR (v_dashboard->'metrics'->>'recoveredOrders')::integer<>0
   OR (v_dashboard->'metrics'->>'revenueRecovered')::numeric<>0 THEN
  RAISE EXCEPTION 'Store B pixel attribution leaked into Store A dashboard: %',v_dashboard;
 END IF;


 -- Refunds reconcile through the same exact-store attribution row. A full
 -- refund reverses the recovered revenue and removes it from dashboard totals.
 INSERT INTO henvalt.shopify_order_refund_adjustments_v2(
  tenant_id,shopify_connection_id,order_identity_id,shopify_refund_id,
  refund_amount,currency,refunded_at,source_delivery_id
 ) VALUES(v_tenant,v_connection,v_attributed_order_id,
  'pixel-refund-partial-'||gen_random_uuid()::text,25.50,'USD',now(),v_source_delivery);
 IF NOT EXISTS(
  SELECT 1 FROM henvalt.shopify_recovery_attributions_v2
  WHERE id=v_attr_id AND status='CONFIRMED'
    AND refunded_amount=25.50 AND net_recovered_amount=100.00
 ) THEN
  RAISE EXCEPTION 'Pixel attribution did not reduce net revenue after partial refund';
 END IF;
 UPDATE henvalt.shopify_order_identity_v2
 SET financial_status='partially_refunded',updated_at=now()
 WHERE id=v_attributed_order_id;
 INSERT INTO henvalt.shopify_order_refund_adjustments_v2(
  tenant_id,shopify_connection_id,order_identity_id,shopify_refund_id,
  refund_amount,currency,refunded_at,source_delivery_id
 ) VALUES(v_tenant,v_connection,v_attributed_order_id,
  'pixel-refund-full-'||gen_random_uuid()::text,100.00,'USD',now(),v_source_delivery);
 UPDATE henvalt.shopify_order_identity_v2
 SET financial_status='refunded',updated_at=now()
 WHERE id=v_attributed_order_id;
 IF NOT EXISTS(
  SELECT 1 FROM henvalt.shopify_recovery_attributions_v2
  WHERE id=v_attr_id AND status='REVERSED'
    AND refunded_amount=125.50 AND net_recovered_amount=0
 ) THEN
  RAISE EXCEPTION 'Pixel attribution did not reverse after full refund';
 END IF;
 v_dashboard:=henvalt.control_plane_dashboard_summary_v2(
  v_connection,now()-interval '1 day',now()
 );
 IF (v_dashboard->'metrics'->>'recoveredOrders')::integer<>0
   OR (v_dashboard->'metrics'->>'revenueRecovered')::numeric<>0 THEN
  RAISE EXCEPTION 'Dashboard continued to count fully refunded pixel revenue: %',v_dashboard;
 END IF;

END;
$test$;
ROLLBACK;
SELECT 'shopify_pixel_attempt_outcome_lifecycle_passed' AS result;

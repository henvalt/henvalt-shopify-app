-- Positive-path pixel attempt cost-state transitions on disposable PostgreSQL only.
-- No permit is minted and no provider or customer request is made.
BEGIN;
DO $test$
DECLARE
 v_tenant uuid:='00000000-0000-4000-8000-000000000001';
 v_connection uuid; v_customer uuid; v_provider text; v_app_key text;
 v_session uuid; v_inbox uuid; v_candidate uuid; v_opportunity uuid; v_attempt uuid;
 v_result jsonb; v_reservation_status text;
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
END;
$test$;
ROLLBACK;
SELECT 'shopify_pixel_attempt_outcome_lifecycle_passed' AS result;

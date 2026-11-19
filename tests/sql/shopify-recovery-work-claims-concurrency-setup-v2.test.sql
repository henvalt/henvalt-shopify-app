-- Disposable fixture for a true concurrent duplicate-claim race.
\set ON_ERROR_STOP on
CREATE TABLE henvalt.test_recovery_work_claim_fixture_v2(
 opportunity_id uuid PRIMARY KEY,
 pixel_candidate_id uuid NOT NULL,
 session_identity_id uuid NOT NULL,
 inbox_event_id uuid NOT NULL,
 tenant_id uuid NOT NULL,
 shopify_connection_id uuid NOT NULL
);
DO $setup$
DECLARE
 v_tenant uuid:='00000000-0000-4000-8000-000000000001';
 v_connection uuid; v_customer uuid; v_app_key text;
 v_inbox uuid; v_session uuid; v_candidate uuid; v_opportunity uuid; v_message_context jsonb;
 v_receipt uuid; v_checkout uuid; v_checkout_candidate uuid; v_checkout_opportunity uuid;
 v_intervention uuid; v_materialized jsonb; v_checkout_token text;
 v_provider_key text; v_sender_id uuid; v_sender_context jsonb; v_other_connection uuid;
BEGIN
 SELECT id,app_key INTO v_connection,v_app_key
 FROM henvalt.shopify_connections
 WHERE tenant_id=v_tenant AND shop_domain='store-b.myshopify.com';
 SELECT id INTO v_customer FROM henvalt.shopify_customer_identity_v2
 WHERE tenant_id=v_tenant AND shopify_connection_id=v_connection
  AND external_customer_reference='12345';
 IF v_connection IS NULL OR v_customer IS NULL OR v_app_key IS NULL THEN
  RAISE EXCEPTION 'Work-claim concurrency fixture requires exact Store B identity';
 END IF;
 INSERT INTO henvalt.shopify_pixel_event_inbox_v2(
  tenant_id,shopify_connection_id,source_event_id,event_type,event_digest,
  occurred_at,analytics_processing_allowed,marketing_allowed,client_reference,
  customer_reference,payload,status,processed_at
 ) VALUES(v_tenant,v_connection,'claim-race-'||gen_random_uuid()::text,
  'product_added_to_cart',
  encode(extensions.digest(convert_to(gen_random_uuid()::text,'UTF8'),'sha256'),'hex'),
  now()-interval '2 hours',true,false,'claim-race-browser-'||gen_random_uuid()::text,
  '12345','{"product":{"id":"claim-race-product"}}'::jsonb,'PROCESSED',now())
 RETURNING id INTO v_inbox;
 INSERT INTO henvalt.shopify_session_identity_v2(
  tenant_id,shopify_connection_id,session_reference,customer_identity_id
 ) VALUES(v_tenant,v_connection,'claim-race-session-'||gen_random_uuid()::text,v_customer)
 RETURNING id INTO v_session;
 INSERT INTO henvalt.shopify_pixel_recovery_candidate_v2(
  tenant_id,shopify_connection_id,candidate_type,session_identity_id,customer_identity_id,
  source_inbox_event_id,product_key,product_context,last_activity_at,eligible_after,
  status,idempotency_key
 ) VALUES(v_tenant,v_connection,'ABANDONED_CART',v_session,v_customer,v_inbox,
  'claim-race-product','{"product_id":"claim-race-product"}'::jsonb,
  now()-interval '2 hours',now()-interval '1 hour','PROMOTED',
  'claim-race-'||gen_random_uuid()::text)
 RETURNING id INTO v_candidate;
 INSERT INTO henvalt.shopify_recovery_opportunity_v2(
  tenant_id,shopify_connection_id,app_key,candidate_id,checkout_identity_id,
  customer_identity_id,source_delivery_id,pixel_candidate_id,opportunity_type,
  status,idempotency_key
 ) VALUES(v_tenant,v_connection,v_app_key,NULL,NULL,v_customer,NULL,v_candidate,
  'ABANDONED_CART','REVIEW_REQUIRED','claim-race-opportunity-'||gen_random_uuid()::text)
 RETURNING id INTO v_opportunity;
 INSERT INTO henvalt.test_recovery_work_claim_fixture_v2(
  opportunity_id,pixel_candidate_id,session_identity_id,inbox_event_id,
  tenant_id,shopify_connection_id
 ) VALUES(v_opportunity,v_candidate,v_session,v_inbox,v_tenant,v_connection);

 PERFORM pg_catalog.set_config('request.jwt.claim.role','service_role',true);
 v_message_context:=henvalt.resolve_shopify_recovery_message_context_v2(
  'PIXEL_OPPORTUNITY',v_opportunity
 );
 IF v_message_context->>'ready'<>'true'
    OR v_message_context->>'shop_domain'<>'store-b.myshopify.com'
    OR v_message_context->>'opportunity_type'<>'ABANDONED_CART'
    OR v_message_context->>'recipient_pii_returned'<>'false'
    OR v_message_context->>'provider_secrets_returned'<>'false'
    OR v_message_context->>'delivery_authorized'<>'false' THEN
  RAISE EXCEPTION 'Pixel recovery message context did not return safe exact-store metadata: %',v_message_context;
 END IF;

 -- Exercise the separate checkout intervention branch using a fresh synthetic
 -- checkout identity bound to a verified Store B receipt from earlier CI setup.
 UPDATE henvalt.shopify_connections SET active=true
 WHERE id=v_connection AND tenant_id=v_tenant;
 SELECT source_delivery_id INTO v_receipt
 FROM henvalt.shopify_checkout_identity_v2
 WHERE tenant_id=v_tenant AND shopify_connection_id=v_connection
   AND source_delivery_id IS NOT NULL
 LIMIT 1;
 IF v_receipt IS NULL THEN
  RAISE EXCEPTION 'Checkout message-context fixture requires an existing verified Store B receipt';
 END IF;

 v_checkout_token:='message-context-token-'||gen_random_uuid()::text;
 INSERT INTO henvalt.shopify_checkout_identity_v2(
  tenant_id,shopify_connection_id,shopify_checkout_id,checkout_token,
  shopify_checkout_token,customer_identity_id,source_delivery_id,
  checkout_status,created_at,updated_at
 ) VALUES(
  v_tenant,v_connection,'message-context-checkout-'||gen_random_uuid()::text,
  v_checkout_token,v_checkout_token,
  v_customer,v_receipt,'OPEN',now()-interval '2 hours',now()-interval '2 hours'
 ) RETURNING id INTO v_checkout;

 INSERT INTO henvalt.shopify_checkout_recovery_candidate_v2(
  tenant_id,shopify_connection_id,checkout_identity_id,checkout_token,
  source_delivery_id,last_activity_at,eligible_after,state
 ) SELECT v_tenant,v_connection,v_checkout,ch.shopify_checkout_token,
  v_receipt,now()-interval '2 hours',now()-interval '1 hour',
  'READY_FOR_CONTACT_RESOLUTION'
 FROM henvalt.shopify_checkout_identity_v2 ch WHERE ch.id=v_checkout
 RETURNING id INTO v_checkout_candidate;

 INSERT INTO henvalt.shopify_recovery_opportunity_v2(
  tenant_id,shopify_connection_id,app_key,candidate_id,checkout_identity_id,
  customer_identity_id,source_delivery_id,opportunity_type,status,idempotency_key
 ) VALUES(v_tenant,v_connection,v_app_key,v_checkout_candidate,v_checkout,
  v_customer,v_receipt,'ABANDONED_CHECKOUT','CONTACT_RESOLUTION_PENDING',
  'message-context-checkout-'||gen_random_uuid()::text)
 RETURNING id INTO v_checkout_opportunity;

 v_materialized:=henvalt.materialize_shopify_checkout_interventions_v2(10);
 SELECT id INTO v_intervention
 FROM henvalt.shopify_recovery_intervention_v2
 WHERE opportunity_id=v_checkout_opportunity
  AND tenant_id=v_tenant AND shopify_connection_id=v_connection
  AND step_number=1 AND status='READY_FOR_AUTHORIZATION';
 IF v_materialized->>'accepted'<>'true' OR v_intervention IS NULL THEN
  RAISE EXCEPTION 'Checkout message-context fixture did not materialize an intervention: %, %',v_materialized,v_intervention;
 END IF;

 v_message_context:=henvalt.resolve_shopify_recovery_message_context_v2(
  'CHECKOUT_INTERVENTION',v_intervention
 );
 IF v_message_context->>'ready'<>'true'
    OR v_message_context->>'shop_domain'<>'store-b.myshopify.com'
    OR v_message_context->>'opportunity_type'<>'ABANDONED_CHECKOUT'
    OR v_message_context->>'recipient_pii_returned'<>'false'
    OR v_message_context->>'provider_secrets_returned'<>'false'
    OR v_message_context->>'delivery_authorized'<>'false' THEN
  RAISE EXCEPTION 'Checkout recovery message context did not return safe exact-store metadata: %',v_message_context;
 END IF;

 -- Remove only this disposable checkout fixture; leave the shared verified
 -- webhook receipt and customer identity untouched.
 DELETE FROM henvalt.shopify_recovery_intervention_v2 WHERE id=v_intervention;
 DELETE FROM henvalt.shopify_recovery_opportunity_v2 WHERE id=v_checkout_opportunity;
 DELETE FROM henvalt.shopify_checkout_recovery_candidate_v2 WHERE id=v_checkout_candidate;
 DELETE FROM henvalt.shopify_checkout_identity_v2 WHERE id=v_checkout;

 -- Sender profile resolution is a separate pre-permit, exact-store service RPC.
 v_provider_key:='sender-preflight-'||replace(gen_random_uuid()::text,'-','');
 INSERT INTO henvalt.shopify_mailer_provider_registry_v2(
  tenant_id,provider_account_key,mailersend_domain_id,webhook_secret_ref,
  recipient_fingerprint_secret_ref,status,email_unit_cost_amount,email_unit_cost_currency
 ) VALUES(v_tenant,v_provider_key,'sender-preflight-domain-'||replace(gen_random_uuid()::text,'-',''),
  'vault://sender-preflight-webhook','vault://sender-preflight-fingerprint',
  'ACTIVE',0.01,'USD');
 INSERT INTO henvalt.shopify_sender_profiles_v2(
  tenant_id,shopify_connection_id,provider_account_key,from_email,from_name,
  status,verified_at
 ) VALUES(v_tenant,v_connection,v_provider_key,'recovery@store-b.example',
  'Store B Recovery','ACTIVE',now())
 RETURNING id INTO v_sender_id;

 v_sender_context:=henvalt.resolve_shopify_sender_profile_for_delivery_v2(
  v_sender_id,v_connection,v_provider_key
 );
 IF v_sender_context->>'ready'<>'true'
    OR v_sender_context->>'from_email'<>'recovery@store-b.example'
    OR v_sender_context->>'from_name'<>'Store B Recovery'
    OR v_sender_context->>'recipient_pii_returned'<>'false'
    OR v_sender_context->>'delivery_authorized'<>'false' THEN
  RAISE EXCEPTION 'Verified sender preflight did not return safe exact-store sender data: %',v_sender_context;
 END IF;

 SELECT id INTO v_other_connection
 FROM henvalt.shopify_connections
 WHERE tenant_id=v_tenant AND shop_domain='store-a.myshopify.com';
 IF v_other_connection IS NOT NULL THEN
  v_sender_context:=henvalt.resolve_shopify_sender_profile_for_delivery_v2(
   v_sender_id,v_other_connection,v_provider_key
  );
  IF v_sender_context->>'ready'<>'false' THEN
   RAISE EXCEPTION 'Sender profile crossed exact-store boundary: %',v_sender_context;
  END IF;
 END IF;

 DELETE FROM henvalt.shopify_sender_profiles_v2 WHERE id=v_sender_id;
 DELETE FROM henvalt.shopify_mailer_provider_registry_v2
 WHERE tenant_id=v_tenant AND provider_account_key=v_provider_key;
END;
$setup$;

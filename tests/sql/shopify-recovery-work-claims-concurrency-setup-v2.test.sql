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
END;
$setup$;

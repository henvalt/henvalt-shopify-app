-- HENVALT exact-store checkout intervention materialization V2.
-- PREPARATION ONLY. Creates orchestration metadata, never a permit or send.
BEGIN;

CREATE INDEX IF NOT EXISTS shopify_recovery_intervention_v2_status_scheduled_idx
 ON henvalt.shopify_recovery_intervention_v2(status,scheduled_at)
 WHERE status='READY_FOR_AUTHORIZATION';

CREATE OR REPLACE FUNCTION henvalt.materialize_shopify_checkout_interventions_v2(
 p_limit integer DEFAULT 100
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=''
AS $function$
DECLARE
 v_created integer:=0;
BEGIN
 IF current_setting('request.jwt.claim.role',true) IS DISTINCT FROM 'service_role' THEN
  RAISE EXCEPTION 'service_role_required' USING ERRCODE='42501';
 END IF;
 IF p_limit IS NULL OR p_limit<1 OR p_limit>500 THEN
  RETURN jsonb_build_object('accepted',false,'code','INVALID_LIMIT');
 END IF;

 WITH selected AS (
  SELECT
   o.id AS opportunity_id,o.tenant_id,o.shopify_connection_id,
   o.customer_identity_id,o.created_at
  FROM henvalt.shopify_recovery_opportunity_v2 o
  JOIN henvalt.shopify_checkout_recovery_candidate_v2 c
   ON c.id=o.candidate_id AND c.tenant_id=o.tenant_id
   AND c.shopify_connection_id=o.shopify_connection_id
  JOIN henvalt.shopify_checkout_identity_v2 ch
   ON ch.id=o.checkout_identity_id AND ch.tenant_id=o.tenant_id
   AND ch.shopify_connection_id=o.shopify_connection_id
  JOIN henvalt.shopify_connections sc
   ON sc.id=o.shopify_connection_id AND sc.tenant_id=o.tenant_id
   AND sc.active IS TRUE
  JOIN henvalt.shopify_app_registry ar
   ON ar.app_key=o.app_key AND ar.lifecycle_status='active'
  JOIN henvalt.tenants t ON t.id=o.tenant_id AND t.status='ACTIVE'
  WHERE o.opportunity_type='ABANDONED_CHECKOUT'
   AND o.status='CONTACT_RESOLUTION_PENDING'
   AND o.customer_identity_id IS NOT NULL
   AND c.state='READY_FOR_CONTACT_RESOLUTION'
   AND c.eligible_after<=now()
   AND ch.checkout_status='OPEN'
   AND ch.customer_identity_id=o.customer_identity_id
   AND ch.shopify_checkout_token=c.checkout_token
   AND NOT EXISTS (
    SELECT 1 FROM henvalt.shopify_order_identity_v2 ord
    WHERE ord.tenant_id=o.tenant_id
     AND ord.shopify_connection_id=o.shopify_connection_id
     AND ord.checkout_token=c.checkout_token
   )
   AND NOT EXISTS (
    SELECT 1 FROM henvalt.shopify_recovery_intervention_v2 i
    WHERE i.opportunity_id=o.id AND i.tenant_id=o.tenant_id
     AND i.shopify_connection_id=o.shopify_connection_id
     AND i.step_number=1
   )
  ORDER BY o.created_at,o.id
  LIMIT p_limit
  FOR UPDATE OF o,c,ch SKIP LOCKED
 ), inserted AS (
  INSERT INTO henvalt.shopify_recovery_intervention_v2(
   tenant_id,shopify_connection_id,opportunity_id,customer_identity_id,
   step_number,status,scheduled_at,updated_at
  )
  SELECT s.tenant_id,s.shopify_connection_id,s.opportunity_id,
   s.customer_identity_id,1,'READY_FOR_AUTHORIZATION',now(),now()
  FROM selected s
  ON CONFLICT(opportunity_id,step_number) DO NOTHING
  RETURNING id
 )
 SELECT count(*)::integer INTO v_created FROM inserted;

 RETURN jsonb_build_object(
  'accepted',true,'interventions_created',v_created,
  'checkout_only',true,'delivery_authorized',false,
  'permit_issued',false,'provider_called',false,
  'recipient_pii_returned',false
 );
END;
$function$;

REVOKE ALL ON FUNCTION henvalt.materialize_shopify_checkout_interventions_v2(integer)
 FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION henvalt.materialize_shopify_checkout_interventions_v2(integer)
 TO service_role;

COMMIT;

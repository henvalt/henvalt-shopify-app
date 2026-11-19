-- HENVALT exact-store V2 recovery work claims and leases.
-- PREPARATION ONLY. Claims orchestration work; they do not authorize or send mail.
BEGIN;

CREATE TABLE henvalt.shopify_recovery_work_claims_v2 (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  work_type text NOT NULL CHECK(work_type IN ('CHECKOUT_INTERVENTION','PIXEL_OPPORTUNITY')),
  work_id uuid NOT NULL,
  tenant_id uuid NOT NULL,
  shopify_connection_id uuid NOT NULL,
  worker_id text NOT NULL CHECK(worker_id ~ '^[A-Za-z0-9._:-]{3,80}$'),
  lease_expires_at timestamptz NOT NULL,
  next_attempt_at timestamptz NOT NULL DEFAULT now(),
  attempt_count integer NOT NULL DEFAULT 1 CHECK(attempt_count>0),
  completed_at timestamptz,
  last_result text CHECK(last_result IS NULL OR last_result IN ('HANDOFF_ACCEPTED','TERMINAL','DEFERRED')),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT shopify_recovery_work_claims_v2_work_uidx UNIQUE(work_type,work_id),
  CONSTRAINT shopify_recovery_work_claims_v2_scope_fkey
    FOREIGN KEY(shopify_connection_id,tenant_id)
    REFERENCES henvalt.shopify_connections(id,tenant_id)
    ON UPDATE RESTRICT ON DELETE RESTRICT,
  CONSTRAINT shopify_recovery_work_claims_v2_completion_check
    CHECK ((completed_at IS NULL) OR last_result IN ('HANDOFF_ACCEPTED','TERMINAL'))
);

CREATE INDEX shopify_recovery_work_claims_v2_due_idx
 ON henvalt.shopify_recovery_work_claims_v2(next_attempt_at,lease_expires_at)
 WHERE completed_at IS NULL;

CREATE INDEX shopify_recovery_intervention_v2_due_idx
 ON henvalt.shopify_recovery_intervention_v2(scheduled_at,id)
 WHERE status='READY_FOR_AUTHORIZATION';

CREATE INDEX shopify_recovery_opportunity_v2_pixel_review_idx
 ON henvalt.shopify_recovery_opportunity_v2(updated_at,id)
 WHERE status='REVIEW_REQUIRED' AND pixel_candidate_id IS NOT NULL;

ALTER TABLE henvalt.shopify_recovery_work_claims_v2 ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON henvalt.shopify_recovery_work_claims_v2 FROM PUBLIC,anon,authenticated,service_role;

COMMENT ON TABLE henvalt.shopify_recovery_work_claims_v2 IS
 'Service-only exact-store work lease ledger for n8n orchestration. Stores opaque work IDs only; no recipient PII, tokens, message content or delivery authority.';

CREATE OR REPLACE FUNCTION henvalt.claim_shopify_recovery_work_v2(
 p_worker_id text,
 p_limit integer DEFAULT 25,
 p_lease_seconds integer DEFAULT 180
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=''
AS $function$
DECLARE
 v_work record;
 v_claim_id uuid;
 v_new_id uuid;
 v_items jsonb:='[]'::jsonb;
 v_claimed integer:=0;
BEGIN
 IF current_setting('request.jwt.claim.role',true) IS DISTINCT FROM 'service_role' THEN
  RAISE EXCEPTION 'service_role_required' USING ERRCODE='42501';
 END IF;
 IF p_worker_id IS NULL OR p_worker_id !~ '^[A-Za-z0-9._:-]{3,80}$'
   OR p_limit IS NULL OR p_limit<1 OR p_limit>100
   OR p_lease_seconds IS NULL OR p_lease_seconds<30 OR p_lease_seconds>900 THEN
  RETURN jsonb_build_object('accepted',false,'code','INVALID_CLAIM_POLICY');
 END IF;

 FOR v_work IN
  SELECT q.*
  FROM (
   SELECT
    'CHECKOUT_INTERVENTION'::text AS work_type,
    i.id AS work_id,i.tenant_id,i.shopify_connection_id,
    i.opportunity_id,i.id AS intervention_id,
    o.opportunity_type,i.scheduled_at AS due_at,0 AS priority
   FROM henvalt.shopify_recovery_intervention_v2 i
   JOIN henvalt.shopify_recovery_opportunity_v2 o
    ON o.id=i.opportunity_id AND o.tenant_id=i.tenant_id
    AND o.shopify_connection_id=i.shopify_connection_id
   JOIN henvalt.shopify_checkout_recovery_candidate_v2 c
    ON c.id=o.candidate_id AND c.tenant_id=o.tenant_id
    AND c.shopify_connection_id=o.shopify_connection_id
   JOIN henvalt.shopify_checkout_identity_v2 ch
    ON ch.id=o.checkout_identity_id AND ch.tenant_id=o.tenant_id
    AND ch.shopify_connection_id=o.shopify_connection_id
   JOIN henvalt.shopify_connections sc
    ON sc.id=i.shopify_connection_id AND sc.tenant_id=i.tenant_id AND sc.active IS TRUE
   JOIN henvalt.shopify_app_registry ar
    ON ar.app_key=o.app_key AND ar.lifecycle_status='active'
   JOIN henvalt.tenants t ON t.id=i.tenant_id AND t.status='ACTIVE'
   WHERE i.status='READY_FOR_AUTHORIZATION'
    AND i.scheduled_at<=now()
    AND o.status='CONTACT_RESOLUTION_PENDING'
    AND c.state='READY_FOR_CONTACT_RESOLUTION'
    AND ch.checkout_status='OPEN'
    AND NOT EXISTS (
     SELECT 1 FROM henvalt.shopify_order_identity_v2 ord
     WHERE ord.tenant_id=i.tenant_id
      AND ord.shopify_connection_id=i.shopify_connection_id
      AND ord.checkout_token=c.checkout_token
    )
    AND NOT EXISTS (
     SELECT 1 FROM henvalt.shopify_recovery_send_attempt_v2 a
     WHERE a.intervention_id=i.id AND a.tenant_id=i.tenant_id
      AND a.shopify_connection_id=i.shopify_connection_id
    )
   UNION ALL
   SELECT
    'PIXEL_OPPORTUNITY'::text AS work_type,
    o.id AS work_id,o.tenant_id,o.shopify_connection_id,
    o.id AS opportunity_id,NULL::uuid AS intervention_id,
    o.opportunity_type,c.eligible_after AS due_at,1 AS priority
   FROM henvalt.shopify_recovery_opportunity_v2 o
   JOIN henvalt.shopify_pixel_recovery_candidate_v2 c
    ON c.id=o.pixel_candidate_id AND c.tenant_id=o.tenant_id
    AND c.shopify_connection_id=o.shopify_connection_id
   JOIN henvalt.shopify_connections sc
    ON sc.id=o.shopify_connection_id AND sc.tenant_id=o.tenant_id AND sc.active IS TRUE
   JOIN henvalt.shopify_app_registry ar
    ON ar.app_key=o.app_key AND ar.lifecycle_status='active'
   JOIN henvalt.tenants t ON t.id=o.tenant_id AND t.status='ACTIVE'
   WHERE o.opportunity_type IN ('ABANDONED_CART','BROWSE_ABANDONMENT')
    AND o.status='REVIEW_REQUIRED'
    AND o.customer_identity_id IS NOT NULL
    AND c.customer_identity_id=o.customer_identity_id
    AND c.status='PROMOTED'
    AND c.eligible_after<=now()
    AND NOT EXISTS (
     SELECT 1 FROM henvalt.shopify_order_identity_v2 ord
     WHERE ord.tenant_id=o.tenant_id
      AND ord.shopify_connection_id=o.shopify_connection_id
      AND ord.customer_identity_id=o.customer_identity_id
      AND ord.ordered_at>=c.last_activity_at
      AND ord.cancelled_at IS NULL
    )
    AND NOT EXISTS (
     SELECT 1 FROM henvalt.shopify_pixel_send_attempts_v2 a
     WHERE a.opportunity_id=o.id AND a.tenant_id=o.tenant_id
      AND a.shopify_connection_id=o.shopify_connection_id
    )
    AND NOT EXISTS (
     SELECT 1 FROM henvalt.shopify_recovery_intervention_v2 i
     WHERE i.opportunity_id=o.id AND i.tenant_id=o.tenant_id
      AND i.shopify_connection_id=o.shopify_connection_id
    )
  ) q
  WHERE NOT EXISTS (
   SELECT 1 FROM henvalt.shopify_recovery_work_claims_v2 old
   WHERE old.work_type=q.work_type AND old.work_id=q.work_id
    AND (old.completed_at IS NOT NULL
      OR old.lease_expires_at>now()
      OR old.next_attempt_at>now())
  )
  ORDER BY q.due_at,q.priority,q.work_id
  LIMIT p_limit
 LOOP
  v_new_id:=extensions.gen_random_uuid();
  INSERT INTO henvalt.shopify_recovery_work_claims_v2(
   id,work_type,work_id,tenant_id,shopify_connection_id,worker_id,
   lease_expires_at,next_attempt_at,attempt_count,updated_at
  ) VALUES (
   v_new_id,v_work.work_type,v_work.work_id,v_work.tenant_id,
   v_work.shopify_connection_id,p_worker_id,
   now()+make_interval(secs=>p_lease_seconds),now(),1,now()
  )
  ON CONFLICT(work_type,work_id) DO UPDATE
   SET id=EXCLUDED.id,worker_id=EXCLUDED.worker_id,
       lease_expires_at=EXCLUDED.lease_expires_at,
       next_attempt_at=now(),
       attempt_count=henvalt.shopify_recovery_work_claims_v2.attempt_count+1,
       last_result=NULL,updated_at=now()
   WHERE henvalt.shopify_recovery_work_claims_v2.completed_at IS NULL
    AND henvalt.shopify_recovery_work_claims_v2.lease_expires_at<=now()
    AND henvalt.shopify_recovery_work_claims_v2.next_attempt_at<=now()
  RETURNING id INTO v_claim_id;

  IF v_claim_id IS NOT NULL THEN
   v_claimed:=v_claimed+1;
   -- Return only the three opaque fields required for the handoff.
   -- Tenant/store lineage remains in the private lease row and is revalidated
   -- by the delivery Edge Function; it must not enter n8n execution data.
   v_items:=v_items||jsonb_build_array(jsonb_build_object(
    'lease_id',v_claim_id,
    'work_type',v_work.work_type,
    'work_id',v_work.work_id
   ));
  END IF;
  v_claim_id:=NULL;
 END LOOP;

 RETURN jsonb_build_object(
  'accepted',true,'claimed',v_claimed,'items',v_items,
  'delivery_authorized',false,'provider_called',false,'recipient_pii_returned',false
 );
END;
$function$;

CREATE OR REPLACE FUNCTION henvalt.finish_shopify_recovery_work_claim_v2(
 p_lease_id uuid,
 p_worker_id text,
 p_outcome text,
 p_retry_after interval DEFAULT interval '1 hour'
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=''
AS $function$
DECLARE v_claim henvalt.shopify_recovery_work_claims_v2%ROWTYPE;
BEGIN
 IF current_setting('request.jwt.claim.role',true) IS DISTINCT FROM 'service_role' THEN
  RAISE EXCEPTION 'service_role_required' USING ERRCODE='42501';
 END IF;
 IF p_lease_id IS NULL OR p_worker_id IS NULL
   OR p_worker_id !~ '^[A-Za-z0-9._:-]{3,80}$'
   OR p_outcome IS NULL OR p_outcome NOT IN ('HANDOFF_ACCEPTED','TERMINAL','DEFERRED')
   OR p_retry_after IS NULL OR p_retry_after<interval '0 seconds'
   OR p_retry_after>interval '24 hours' THEN
  RETURN jsonb_build_object('finished',false,'code','INVALID_COMPLETION');
 END IF;

 SELECT * INTO v_claim
 FROM henvalt.shopify_recovery_work_claims_v2
 WHERE id=p_lease_id AND worker_id=p_worker_id
  AND completed_at IS NULL AND lease_expires_at>now()
 FOR UPDATE;
 IF NOT FOUND THEN
  RETURN jsonb_build_object('finished',false,'code','LEASE_NOT_ACTIVE');
 END IF;

 IF p_outcome='DEFERRED' THEN
  UPDATE henvalt.shopify_recovery_work_claims_v2
   SET lease_expires_at=now(),next_attempt_at=now()+p_retry_after,
       worker_id='deferred',last_result='DEFERRED',updated_at=now()
   WHERE id=p_lease_id;
  RETURN jsonb_build_object('finished',true,'outcome','DEFERRED',
   'retry_at',now()+p_retry_after,'delivery_authorized',false);
 END IF;

 UPDATE henvalt.shopify_recovery_work_claims_v2
  SET completed_at=now(),last_result=p_outcome,updated_at=now()
  WHERE id=p_lease_id;
 RETURN jsonb_build_object('finished',true,'outcome',p_outcome,
  'delivery_authorized',false);
END;
$function$;

REVOKE ALL ON FUNCTION henvalt.claim_shopify_recovery_work_v2(text,integer,integer)
 FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION henvalt.finish_shopify_recovery_work_claim_v2(uuid,text,text,interval)
 FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION henvalt.claim_shopify_recovery_work_v2(text,integer,integer)
 TO service_role;
GRANT EXECUTE ON FUNCTION henvalt.finish_shopify_recovery_work_claim_v2(uuid,text,text,interval)
 TO service_role;

COMMIT;

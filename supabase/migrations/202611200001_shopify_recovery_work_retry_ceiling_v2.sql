-- HENVALT finite retry ceiling and operator-review ledger for V2 recovery claims.
-- PREPARATION ONLY. This migration does not authorize or send mail.
BEGIN;

ALTER TABLE henvalt.shopify_recovery_work_claims_v2
  ADD COLUMN max_attempt_count integer NOT NULL DEFAULT 5
    CHECK(max_attempt_count BETWEEN 1 AND 10),
  ADD COLUMN exhausted_at timestamptz;

ALTER TABLE henvalt.shopify_recovery_work_claims_v2
  DROP CONSTRAINT shopify_recovery_work_claims_v2_last_result_check,
  ADD CONSTRAINT shopify_recovery_work_claims_v2_last_result_check
    CHECK(last_result IS NULL OR last_result IN ('HANDOFF_ACCEPTED','TERMINAL','DEFERRED','EXHAUSTED')),
  ADD CONSTRAINT shopify_recovery_work_claims_v2_exhaustion_check
    CHECK ((exhausted_at IS NULL AND last_result IS DISTINCT FROM 'EXHAUSTED')
        OR (exhausted_at IS NOT NULL AND last_result='EXHAUSTED' AND completed_at IS NULL));

CREATE INDEX shopify_recovery_work_claims_v2_exhausted_idx
  ON henvalt.shopify_recovery_work_claims_v2(exhausted_at,updated_at)
  WHERE exhausted_at IS NOT NULL;

COMMENT ON COLUMN henvalt.shopify_recovery_work_claims_v2.max_attempt_count IS
  'Finite maximum number of Recovery claims for this work item; defaults to five.';
COMMENT ON COLUMN henvalt.shopify_recovery_work_claims_v2.exhausted_at IS
  'Set when the final permitted attempt is deferred or its lease expires; exhausted work is retained for operator review and is never automatically reclaimed.';

CREATE OR REPLACE VIEW henvalt.shopify_recovery_exhausted_work_v2 AS
SELECT id,work_type,work_id,tenant_id,shopify_connection_id,
       attempt_count,max_attempt_count,exhausted_at,last_result,updated_at
FROM henvalt.shopify_recovery_work_claims_v2
WHERE exhausted_at IS NOT NULL;

REVOKE ALL ON henvalt.shopify_recovery_exhausted_work_v2 FROM PUBLIC,anon,authenticated;
GRANT SELECT ON henvalt.shopify_recovery_exhausted_work_v2 TO service_role;

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
 v_exhausted integer:=0;
BEGIN
 IF current_setting('request.jwt.claim.role',true) IS DISTINCT FROM 'service_role' THEN
  RAISE EXCEPTION 'service_role_required' USING ERRCODE='42501';
 END IF;
 IF p_worker_id IS NULL OR p_worker_id !~ '^[A-Za-z0-9._:-]{3,80}$'
   OR p_limit IS NULL OR p_limit<1 OR p_limit>100
   OR p_lease_seconds IS NULL OR p_lease_seconds<30 OR p_lease_seconds>900 THEN
  RETURN jsonb_build_object('accepted',false,'code','INVALID_CLAIM_POLICY');
 END IF;

 -- A worker crash on the fifth claim cannot make the item retry forever.
 -- Once that final lease expires, preserve the row in the operator-review view.
 UPDATE henvalt.shopify_recovery_work_claims_v2
 SET exhausted_at=now(),last_result='EXHAUSTED',worker_id='exhausted',updated_at=now()
 WHERE completed_at IS NULL AND exhausted_at IS NULL
   AND attempt_count>=max_attempt_count
   AND lease_expires_at<=now() AND next_attempt_at<=now();
 GET DIAGNOSTICS v_exhausted = ROW_COUNT;

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
      OR old.exhausted_at IS NOT NULL
      OR old.attempt_count>=old.max_attempt_count
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
    AND henvalt.shopify_recovery_work_claims_v2.exhausted_at IS NULL
    AND henvalt.shopify_recovery_work_claims_v2.attempt_count
        < henvalt.shopify_recovery_work_claims_v2.max_attempt_count
    AND henvalt.shopify_recovery_work_claims_v2.lease_expires_at<=now()
    AND henvalt.shopify_recovery_work_claims_v2.next_attempt_at<=now()
  RETURNING id INTO v_claim_id;

  IF v_claim_id IS NOT NULL THEN
   v_claimed:=v_claimed+1;
   v_items:=v_items||jsonb_build_array(jsonb_build_object(
    'lease_id',v_claim_id,'work_type',v_work.work_type,'work_id',v_work.work_id
   ));
  END IF;
  v_claim_id:=NULL;
 END LOOP;

 RETURN jsonb_build_object(
  'accepted',true,'claimed',v_claimed,'items',v_items,
  'exhausted_marked',v_exhausted,
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
  AND completed_at IS NULL AND exhausted_at IS NULL AND lease_expires_at>now()
 FOR UPDATE;
 IF NOT FOUND THEN
  RETURN jsonb_build_object('finished',false,'code','LEASE_NOT_ACTIVE');
 END IF;

 IF p_outcome='DEFERRED' AND v_claim.attempt_count>=v_claim.max_attempt_count THEN
  UPDATE henvalt.shopify_recovery_work_claims_v2
   SET exhausted_at=now(),last_result='EXHAUSTED',
       lease_expires_at=now(),next_attempt_at=now(),
       worker_id='exhausted',updated_at=now()
   WHERE id=p_lease_id;
  RETURN jsonb_build_object('finished',true,'outcome','DEFERRED',
   'exhausted',true,'reason_code','retry_limit_reached',
   'delivery_authorized',false);
 END IF;

 IF p_outcome='DEFERRED' THEN
  UPDATE henvalt.shopify_recovery_work_claims_v2
   SET lease_expires_at=now(),next_attempt_at=now()+p_retry_after,
       worker_id='deferred',last_result='DEFERRED',updated_at=now()
   WHERE id=p_lease_id;
  RETURN jsonb_build_object('finished',true,'outcome','DEFERRED',
   'exhausted',false,'retry_at',now()+p_retry_after,'delivery_authorized',false);
 END IF;

 UPDATE henvalt.shopify_recovery_work_claims_v2
  SET completed_at=now(),last_result=p_outcome,updated_at=now()
  WHERE id=p_lease_id;
 RETURN jsonb_build_object('finished',true,'outcome',p_outcome,
  'exhausted',false,'delivery_authorized',false);
END;
$function$;

COMMIT;

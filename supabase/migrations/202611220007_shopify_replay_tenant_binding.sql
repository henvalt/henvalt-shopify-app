-- Bind every explicit tenant argument and webhook lifecycle write to the
-- tenant/webhook persisted on the currently leased replay job.
-- Without this check, a valid lease for tenant A could be paired with a
-- caller-supplied tenant B in SECURITY DEFINER wrappers.
CREATE OR REPLACE FUNCTION henvalt.assert_shopify_replay_tenant_for_write(
  p_job_id uuid,
  p_worker_id text,
  p_lease_id uuid,
  p_tenant_id uuid
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_job_tenant uuid;
  v_webhook_id text;
BEGIN
  PERFORM henvalt.assert_shopify_replay_lease_for_write(p_job_id,p_worker_id,p_lease_id);

  SELECT j.tenant_id, j.payload->>'webhook_id'
    INTO v_job_tenant, v_webhook_id
    FROM henvalt.background_jobs AS j
   WHERE j.id = p_job_id
     AND j.job_type = 'process_shopify_webhook'
     AND j.status = 'CLAIMED'::henvalt.job_status
     AND j.locked_by = p_worker_id
     AND j.lease_id = p_lease_id;

  IF NOT FOUND
     OR p_tenant_id IS NULL
     OR v_job_tenant IS DISTINCT FROM p_tenant_id
     OR v_webhook_id IS NULL
     OR NOT EXISTS (
       SELECT 1
         FROM henvalt.webhook_events AS w
        WHERE w.id::text = v_webhook_id
          AND w.tenant_id = v_job_tenant
     ) THEN
    RAISE EXCEPTION 'SHOPIFY_REPLAY_WRITE_TENANT_BINDING_INVALID'
      USING ERRCODE = '42501';
  END IF;
END;
$function$;

CREATE OR REPLACE FUNCTION henvalt.assert_shopify_replay_webhook_for_write(
  p_job_id uuid,
  p_worker_id text,
  p_lease_id uuid,
  p_webhook_id uuid
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_job_tenant uuid;
  v_job_webhook_id text;
BEGIN
  PERFORM henvalt.assert_shopify_replay_lease_for_write(p_job_id,p_worker_id,p_lease_id);

  SELECT j.tenant_id, j.payload->>'webhook_id'
    INTO v_job_tenant, v_job_webhook_id
    FROM henvalt.background_jobs AS j
   WHERE j.id = p_job_id
     AND j.job_type = 'process_shopify_webhook'
     AND j.status = 'CLAIMED'::henvalt.job_status
     AND j.locked_by = p_worker_id
     AND j.lease_id = p_lease_id;

  IF NOT FOUND
     OR p_webhook_id IS NULL
     OR v_job_webhook_id IS DISTINCT FROM p_webhook_id::text
     OR NOT EXISTS (
       SELECT 1
         FROM henvalt.webhook_events AS w
        WHERE w.id = p_webhook_id
          AND w.tenant_id = v_job_tenant
     ) THEN
    RAISE EXCEPTION 'SHOPIFY_REPLAY_WRITE_WEBHOOK_BINDING_INVALID'
      USING ERRCODE = '42501';
  END IF;
END;
$function$;

REVOKE ALL ON FUNCTION henvalt.assert_shopify_replay_tenant_for_write(uuid,text,uuid,uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION henvalt.assert_shopify_replay_webhook_for_write(uuid,text,uuid,uuid) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION henvalt.assert_shopify_replay_tenant_for_write(uuid,text,uuid,uuid) FROM anon,authenticated;
REVOKE EXECUTE ON FUNCTION henvalt.assert_shopify_replay_webhook_for_write(uuid,text,uuid,uuid) FROM anon,authenticated;
GRANT EXECUTE ON FUNCTION henvalt.assert_shopify_replay_tenant_for_write(uuid,text,uuid,uuid) TO service_role;
GRANT EXECUTE ON FUNCTION henvalt.assert_shopify_replay_webhook_for_write(uuid,text,uuid,uuid) TO service_role;

-- Replace the explicit-tenant wrappers so a lease for one tenant cannot be
-- combined with a different tenant ID in a SECURITY DEFINER business RPC.

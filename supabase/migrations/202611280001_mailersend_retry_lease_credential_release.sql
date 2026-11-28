-- Retry-generation-aware MailerSend credential release.
-- The retry job lease is validated and held before the legacy credential
-- release routine performs its existing tenant/consent/suppression checks.
-- Candidate only: apply only as part of the coordinated staging migration set.

BEGIN;

CREATE OR REPLACE FUNCTION henvalt.get_mailersend_token_for_delivery(
  p_tenant_id uuid,
  p_delivery_request_id uuid,
  p_retry_job_id uuid,
  p_retry_worker_id text,
  p_generation_number integer
) RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO pg_catalog, henvalt, vault, auth, pg_temp
AS $function$
BEGIN
  IF auth.role() IS DISTINCT FROM 'service_role' THEN
    RAISE EXCEPTION 'SERVICE_ROLE_REQUIRED' USING ERRCODE='42501';
  END IF;

  IF p_tenant_id IS NULL OR p_delivery_request_id IS NULL
     OR p_retry_job_id IS NULL OR NULLIF(btrim(p_retry_worker_id),'') IS NULL
     OR p_generation_number IS NULL OR p_generation_number NOT IN (2,3) THEN
    RAISE EXCEPTION 'DELIVERY_RETRY_CREDENTIAL_IDENTITY_REQUIRED' USING ERRCODE='22023';
  END IF;

  PERFORM henvalt.assert_provider_sending_enabled();

  IF EXISTS (
    SELECT 1
      FROM henvalt.delivery_requests dr
      JOIN henvalt.messages m
        ON m.id=dr.message_reference AND m.tenant_id=dr.tenant_id
     WHERE dr.id=p_delivery_request_id
       AND dr.tenant_id=p_tenant_id
       AND m.metadata->>'test_only'='true'
  ) THEN
    RAISE EXCEPTION 'HENVALT_ONE_OFF_TEST_SEND_DISABLED' USING ERRCODE='42501';
  END IF;

  -- This locks intervention -> request -> retry job and validates the exact
  -- active worker, lease, tenant, delivery request and immutable generation.
  -- Locks remain held until this function's transaction commits.
  IF henvalt.renew_delivery_retry_job_lease(
    p_tenant_id,p_delivery_request_id,p_retry_job_id,
    p_retry_worker_id,p_generation_number
  ) IS NOT TRUE THEN
    RAISE EXCEPTION 'DELIVERY_RETRY_JOB_CLAIM_INVALID' USING ERRCODE='55000';
  END IF;

  -- Reuse the mature eligibility, suppression, sender-domain and Vault checks.
  -- The lease helper above has already restricted this path to generation 2/3.
  RETURN henvalt.get_mailersend_token_for_delivery_legacy_v1(
    p_tenant_id,p_delivery_request_id
  );
END;
$function$;

REVOKE ALL ON FUNCTION henvalt.get_mailersend_token_for_delivery(uuid,uuid,uuid,text,integer)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION henvalt.get_mailersend_token_for_delivery(uuid,uuid,uuid,text,integer)
  TO service_role;

COMMENT ON FUNCTION henvalt.get_mailersend_token_for_delivery(uuid,uuid,uuid,text,integer) IS
  'Retry-only MailerSend credential release. Validates and holds the exact retry-job lease and generation before reusing the legacy eligibility, suppression, sender-domain and Vault credential checks.';

COMMIT;

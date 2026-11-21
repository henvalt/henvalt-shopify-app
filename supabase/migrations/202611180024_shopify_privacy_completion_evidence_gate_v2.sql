-- Fail-closed privacy completion gate.
-- PREPARATION ONLY. Until export artifacts/delivery attestation and redaction
-- postcondition processors exist, a boolean supplied by a caller is not
-- sufficient evidence that a Shopify privacy request has been completed.

BEGIN;

CREATE OR REPLACE FUNCTION henvalt.complete_shopify_privacy_request_v2(
  p_receipt_id uuid,
  p_claim_token text,
  p_processor_confirmed boolean
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_receipt henvalt.shopify_privacy_webhook_deliveries%ROWTYPE;
BEGIN
  IF p_receipt_id IS NULL
     OR p_claim_token IS NULL
     OR p_claim_token !~ '^[0-9a-f]{64}$'
     OR p_processor_confirmed IS DISTINCT FROM true THEN
    RETURN false;
  END IF;

  -- Revalidate the immutable receipt -> tenant -> connection -> app/store
  -- binding at the state transition boundary, not only at initial claim.
  SELECT r.* INTO v_receipt
  FROM henvalt.shopify_privacy_webhook_deliveries r
  JOIN henvalt.shopify_connections sc
    ON sc.id = r.connection_id
   AND sc.tenant_id = r.tenant_id
   AND sc.app_key = r.app_key
   AND sc.shop_domain = r.shop_domain
  JOIN henvalt.shopify_privacy_processing_jobs_v2 j
    ON j.receipt_id = r.id
  WHERE r.id = p_receipt_id
    AND r.connection_id IS NOT NULL
    AND r.tenant_id IS NOT NULL
    AND j.state = 'CLAIMED'
    AND j.lease_until > pg_catalog.now()
    AND j.claim_token_sha256 = pg_catalog.encode(
      extensions.digest(pg_catalog.convert_to(p_claim_token, 'UTF8'), 'sha256'), 'hex'
    )
  FOR UPDATE OF r, j;

  IF NOT FOUND THEN
    RETURN false;
  END IF;

  -- The export path currently creates only an incomplete JSON preview, and
  -- the redaction path is only an impact preview. No artifact manifest,
  -- merchant delivery attestation, or deletion postcondition exists yet.
  -- Do not mark the Shopify request COMPLETED based on a boolean alone.
  UPDATE henvalt.shopify_privacy_processing_jobs_v2
     SET state = 'REVIEW_REQUIRED',
         claim_token_sha256 = NULL,
         lease_until = NULL,
         completed_at = NULL,
         updated_at = pg_catalog.now(),
         last_failure_code = 'COMPLETION_EVIDENCE_PIPELINE_NOT_IMPLEMENTED'
   WHERE receipt_id = p_receipt_id;

  UPDATE henvalt.shopify_privacy_webhook_deliveries
     SET processing_status = 'REVIEW_REQUIRED',
         processed_at = NULL,
         failure_code = 'COMPLETION_EVIDENCE_PIPELINE_NOT_IMPLEMENTED'
   WHERE id = p_receipt_id;

  RETURN false;
END;
$function$;

REVOKE ALL ON FUNCTION henvalt.complete_shopify_privacy_request_v2(uuid,text,boolean)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION henvalt.complete_shopify_privacy_request_v2(uuid,text,boolean)
  TO service_role;

COMMENT ON FUNCTION henvalt.complete_shopify_privacy_request_v2(uuid,text,boolean) IS
  'Fail-closed completion gate. Revalidates exact store binding and holds the receipt in REVIEW_REQUIRED until durable export delivery or redaction postcondition evidence is implemented.';

COMMIT;

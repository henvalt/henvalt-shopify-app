-- HENVALT privacy artifact purge lease and evidence lifecycle V2.
-- PREPARATION ONLY. Service-side worker must delete and verify the private
-- Storage object before confirming purge. This migration does not touch Storage.

BEGIN;

ALTER TABLE henvalt.shopify_privacy_export_artifacts_v2
  ADD COLUMN IF NOT EXISTS purge_claim_token_sha256 text
    CHECK (purge_claim_token_sha256 IS NULL OR purge_claim_token_sha256 ~ '^[0-9a-f]{64}$'),
  ADD COLUMN IF NOT EXISTS purge_lease_until timestamptz,
  ADD COLUMN IF NOT EXISTS purge_claimed_at timestamptz,
  ADD COLUMN IF NOT EXISTS purge_attempt_count integer NOT NULL DEFAULT 0
    CHECK (purge_attempt_count >= 0),
  ADD COLUMN IF NOT EXISTS purge_failure_code text
    CHECK (purge_failure_code IS NULL OR purge_failure_code ~ '^[A-Z0-9_]{1,64}$');

ALTER TABLE henvalt.shopify_privacy_export_artifacts_v2
  ADD CONSTRAINT shopify_privacy_export_artifacts_purge_claim_pair
  CHECK ((purge_claim_token_sha256 IS NULL) = (purge_lease_until IS NULL));

CREATE INDEX IF NOT EXISTS shopify_privacy_export_artifacts_purge_claim_idx
  ON henvalt.shopify_privacy_export_artifacts_v2 (expires_at, id)
  WHERE state IN ('AVAILABLE', 'PURGE_PENDING');

CREATE OR REPLACE FUNCTION henvalt.claim_shopify_privacy_export_purge_v2(
  p_lease_seconds integer DEFAULT 300
)
RETURNS TABLE (
  artifact_id uuid,
  receipt_id uuid,
  tenant_id uuid,
  connection_id uuid,
  app_key text,
  shop_domain text,
  bucket_id text,
  object_key text,
  expected_sha256_hex text,
  expected_byte_count bigint,
  claim_token text,
  lease_expires_at timestamptz,
  attempt_count integer
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_artifact henvalt.shopify_privacy_export_artifacts_v2%ROWTYPE;
  v_token text;
BEGIN
  IF p_lease_seconds IS NULL OR p_lease_seconds NOT BETWEEN 60 AND 900 THEN
    RAISE EXCEPTION 'artifact purge lease must be between 60 and 900 seconds';
  END IF;

  SELECT a.* INTO v_artifact
  FROM henvalt.shopify_privacy_export_artifacts_v2 a
  JOIN henvalt.shopify_privacy_webhook_deliveries r
    ON r.id = a.receipt_id
   AND r.tenant_id = a.tenant_id
   AND r.connection_id = a.connection_id
   AND r.app_key = a.app_key
   AND r.shop_domain = a.shop_domain
  WHERE (
      a.state = 'PURGE_PENDING'
      OR (a.state = 'AVAILABLE' AND a.expires_at <= pg_catalog.now())
      OR (a.state = 'PURGE_PENDING' AND a.purge_lease_until <= pg_catalog.now())
    )
    AND (a.purge_lease_until IS NULL OR a.purge_lease_until <= pg_catalog.now())
    AND a.purge_attempt_count < 10
  ORDER BY a.expires_at, a.id
  FOR UPDATE OF a SKIP LOCKED
  LIMIT 1;

  IF NOT FOUND THEN
    RETURN;
  END IF;

  v_token := pg_catalog.encode(extensions.gen_random_bytes(32), 'hex');

  UPDATE henvalt.shopify_privacy_export_artifacts_v2 a
     SET state = 'PURGE_PENDING',
         purge_claim_token_sha256 = pg_catalog.encode(
           extensions.digest(pg_catalog.convert_to(v_token, 'UTF8'), 'sha256'), 'hex'
         ),
         purge_claimed_at = pg_catalog.now(),
         purge_lease_until = pg_catalog.now() + pg_catalog.make_interval(secs => p_lease_seconds),
         purge_attempt_count = a.purge_attempt_count + 1,
         purge_failure_code = NULL
   WHERE a.id = v_artifact.id
  RETURNING a.* INTO v_artifact;

  artifact_id := v_artifact.id;
  receipt_id := v_artifact.receipt_id;
  tenant_id := v_artifact.tenant_id;
  connection_id := v_artifact.connection_id;
  app_key := v_artifact.app_key;
  shop_domain := v_artifact.shop_domain;
  bucket_id := v_artifact.bucket_id;
  object_key := v_artifact.object_key;
  expected_sha256_hex := v_artifact.sha256_hex;
  expected_byte_count := v_artifact.byte_count;
  claim_token := v_token;
  lease_expires_at := v_artifact.purge_lease_until;
  attempt_count := v_artifact.purge_attempt_count;
  RETURN NEXT;
END;
$function$;

CREATE OR REPLACE FUNCTION henvalt.confirm_shopify_privacy_export_purged_v2(
  p_artifact_id uuid,
  p_claim_token text,
  p_object_absence_confirmed boolean
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_artifact henvalt.shopify_privacy_export_artifacts_v2%ROWTYPE;
BEGIN
  IF p_artifact_id IS NULL
     OR p_claim_token IS NULL
     OR p_claim_token !~ '^[0-9a-f]{64}$'
     OR p_object_absence_confirmed IS DISTINCT FROM true THEN
    RETURN false;
  END IF;

  SELECT a.* INTO v_artifact
  FROM henvalt.shopify_privacy_export_artifacts_v2 a
  JOIN henvalt.shopify_privacy_webhook_deliveries r
    ON r.id = a.receipt_id
   AND r.tenant_id = a.tenant_id
   AND r.connection_id = a.connection_id
   AND r.app_key = a.app_key
   AND r.shop_domain = a.shop_domain
  WHERE a.id = p_artifact_id
    AND a.state = 'PURGE_PENDING'
    AND a.purge_lease_until > pg_catalog.now()
    AND a.purge_claim_token_sha256 = pg_catalog.encode(
      extensions.digest(pg_catalog.convert_to(p_claim_token, 'UTF8'), 'sha256'), 'hex'
    )
  FOR UPDATE OF a;

  IF NOT FOUND THEN
    RETURN false;
  END IF;

  UPDATE henvalt.shopify_privacy_export_artifacts_v2
     SET state = 'PURGED',
         purged_at = pg_catalog.now(),
         purge_claim_token_sha256 = NULL,
         purge_lease_until = NULL,
         purge_failure_code = NULL
   WHERE id = p_artifact_id;

  INSERT INTO henvalt.shopify_privacy_delivery_evidence_v2 (
    receipt_id, tenant_id, connection_id, app_key, shop_domain,
    artifact_id, event_type, outcome_code, correlation_id
  ) VALUES (
    v_artifact.receipt_id, v_artifact.tenant_id, v_artifact.connection_id,
    v_artifact.app_key, v_artifact.shop_domain, v_artifact.id,
    'ARTIFACT_PURGED', 'PRIVATE_OBJECT_ABSENCE_CONFIRMED', extensions.gen_random_uuid()
  );

  RETURN true;
END;
$function$;

CREATE OR REPLACE FUNCTION henvalt.fail_shopify_privacy_export_purge_v2(
  p_artifact_id uuid,
  p_claim_token text,
  p_failure_code text
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_artifact henvalt.shopify_privacy_export_artifacts_v2%ROWTYPE;
BEGIN
  IF p_artifact_id IS NULL
     OR p_claim_token IS NULL
     OR p_claim_token !~ '^[0-9a-f]{64}$'
     OR p_failure_code IS NULL
     OR p_failure_code !~ '^[A-Z0-9_]{1,64}$' THEN
    RETURN false;
  END IF;

  SELECT a.* INTO v_artifact
  FROM henvalt.shopify_privacy_export_artifacts_v2 a
  WHERE a.id = p_artifact_id
    AND a.state = 'PURGE_PENDING'
    AND a.purge_lease_until > pg_catalog.now()
    AND a.purge_claim_token_sha256 = pg_catalog.encode(
      extensions.digest(pg_catalog.convert_to(p_claim_token, 'UTF8'), 'sha256'), 'hex'
    )
  FOR UPDATE;

  IF NOT FOUND THEN
    RETURN false;
  END IF;

  UPDATE henvalt.shopify_privacy_export_artifacts_v2
     SET purge_claim_token_sha256 = NULL,
         purge_lease_until = NULL,
         purge_failure_code = p_failure_code
   WHERE id = p_artifact_id;

  INSERT INTO henvalt.shopify_privacy_delivery_evidence_v2 (
    receipt_id, tenant_id, connection_id, app_key, shop_domain,
    artifact_id, event_type, outcome_code, correlation_id
  ) VALUES (
    v_artifact.receipt_id, v_artifact.tenant_id, v_artifact.connection_id,
    v_artifact.app_key, v_artifact.shop_domain, v_artifact.id,
    'ARTIFACT_PURGE_FAILED', p_failure_code, extensions.gen_random_uuid()
  );

  RETURN true;
END;
$function$;

REVOKE ALL ON FUNCTION henvalt.claim_shopify_privacy_export_purge_v2(integer)
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION henvalt.confirm_shopify_privacy_export_purged_v2(uuid,text,boolean)
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION henvalt.fail_shopify_privacy_export_purge_v2(uuid,text,text)
  FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION henvalt.claim_shopify_privacy_export_purge_v2(integer)
  TO service_role;
GRANT EXECUTE ON FUNCTION henvalt.confirm_shopify_privacy_export_purged_v2(uuid,text,boolean)
  TO service_role;
GRANT EXECUTE ON FUNCTION henvalt.fail_shopify_privacy_export_purge_v2(uuid,text,text)
  TO service_role;

COMMENT ON FUNCTION henvalt.claim_shopify_privacy_export_purge_v2(integer) IS
  'Service-only leased claim for expired privacy export objects. Returns opaque object locator only to trusted service code.';
COMMENT ON FUNCTION henvalt.confirm_shopify_privacy_export_purged_v2(uuid,text,boolean) IS
  'Marks an artifact PURGED only after the current lease holder confirms the private Storage object is absent; preserves append-only evidence.';
COMMENT ON FUNCTION henvalt.fail_shopify_privacy_export_purge_v2(uuid,text,text) IS
  'Releases a valid purge lease after failure while keeping the artifact PURGE_PENDING for bounded retry/review.';

COMMIT;

-- HENVALT exact-store Shopify privacy processing queue V2.
-- PREPARATION ONLY. This adds a server-only, leased work queue for verified
-- receipts. It does not export or delete customer/store data.
-- A processor must complete the exact-store operation before acknowledging it.

BEGIN;

CREATE TABLE IF NOT EXISTS henvalt.shopify_privacy_processing_jobs_v2 (
  receipt_id uuid PRIMARY KEY,
  state text NOT NULL DEFAULT 'REVIEW_REQUIRED'
    CHECK (state IN ('READY', 'CLAIMED', 'COMPLETED', 'FAILED', 'REVIEW_REQUIRED')),
  attempt_count integer NOT NULL DEFAULT 0 CHECK (attempt_count >= 0),
  claim_token_sha256 text
    CHECK (claim_token_sha256 IS NULL OR claim_token_sha256 ~ '^[0-9a-f]{64}$'),
  lease_until timestamptz,
  claimed_at timestamptz,
  completed_at timestamptz,
  last_failure_code text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT shopify_privacy_processing_jobs_v2_receipt_fkey
    FOREIGN KEY (receipt_id)
    REFERENCES henvalt.shopify_privacy_webhook_deliveries(id)
    ON UPDATE RESTRICT ON DELETE CASCADE,
  CONSTRAINT shopify_privacy_processing_jobs_v2_claim_pair
    CHECK ((claim_token_sha256 IS NULL) = (lease_until IS NULL))
);

CREATE INDEX IF NOT EXISTS shopify_privacy_processing_jobs_v2_ready_idx
  ON henvalt.shopify_privacy_processing_jobs_v2 (created_at, receipt_id)
  WHERE state = 'READY';

CREATE INDEX IF NOT EXISTS shopify_privacy_processing_jobs_v2_expired_idx
  ON henvalt.shopify_privacy_processing_jobs_v2 (lease_until, receipt_id)
  WHERE state = 'CLAIMED';

ALTER TABLE henvalt.shopify_privacy_processing_jobs_v2 ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON henvalt.shopify_privacy_processing_jobs_v2
  FROM PUBLIC, anon, authenticated, service_role;

CREATE OR REPLACE FUNCTION henvalt.enqueue_shopify_privacy_receipt_v2()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_ready boolean;
BEGIN
  v_ready := NEW.connection_id IS NOT NULL
    AND NEW.tenant_id IS NOT NULL
    AND (
      NEW.topic = 'shop/redact'
      OR (NEW.topic IN ('customers/data_request', 'customers/redact')
          AND NEW.customer_id IS NOT NULL)
    );

  INSERT INTO henvalt.shopify_privacy_processing_jobs_v2 (
    receipt_id, state
  ) VALUES (
    NEW.id, CASE WHEN v_ready THEN 'READY' ELSE 'REVIEW_REQUIRED' END
  )
  ON CONFLICT (receipt_id) DO NOTHING;

  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS shopify_privacy_enqueue_after_receipt_v2
  ON henvalt.shopify_privacy_webhook_deliveries;
CREATE TRIGGER shopify_privacy_enqueue_after_receipt_v2
AFTER INSERT ON henvalt.shopify_privacy_webhook_deliveries
FOR EACH ROW
EXECUTE FUNCTION henvalt.enqueue_shopify_privacy_receipt_v2();

REVOKE ALL ON FUNCTION henvalt.enqueue_shopify_privacy_receipt_v2()
  FROM PUBLIC, anon, authenticated, service_role;

CREATE OR REPLACE FUNCTION henvalt.claim_shopify_privacy_request_v2(
  p_lease_seconds integer DEFAULT 300
)
RETURNS TABLE (
  receipt_id uuid,
  claim_token text,
  app_key text,
  tenant_id uuid,
  connection_id uuid,
  shop_domain text,
  topic text,
  customer_id text,
  request_id text,
  body_sha256 text,
  attempt_count integer,
  lease_expires_at timestamptz
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_job henvalt.shopify_privacy_processing_jobs_v2%ROWTYPE;
  v_receipt henvalt.shopify_privacy_webhook_deliveries%ROWTYPE;
  v_token text;
BEGIN
  IF p_lease_seconds IS NULL OR p_lease_seconds NOT BETWEEN 60 AND 900 THEN
    RAISE EXCEPTION 'privacy processing lease must be between 60 and 900 seconds';
  END IF;

  SELECT j.* INTO v_job
  FROM henvalt.shopify_privacy_processing_jobs_v2 j
  JOIN henvalt.shopify_privacy_webhook_deliveries r
    ON r.id = j.receipt_id
  JOIN henvalt.shopify_connections sc
    ON sc.id = r.connection_id
   AND sc.tenant_id = r.tenant_id
   AND sc.app_key = r.app_key
   AND sc.shop_domain = r.shop_domain
  WHERE (
      j.state = 'READY'
      OR (j.state = 'CLAIMED' AND j.lease_until <= pg_catalog.now())
    )
    AND j.attempt_count < 10
    AND r.processing_status IN ('REVIEW_REQUIRED', 'PROCESSING', 'FAILED')
    AND (
      r.topic = 'shop/redact'
      OR (r.topic IN ('customers/data_request', 'customers/redact')
          AND r.customer_id IS NOT NULL)
    )
  ORDER BY j.created_at, j.receipt_id
  FOR UPDATE OF j SKIP LOCKED
  LIMIT 1;

  IF NOT FOUND THEN
    RETURN;
  END IF;

  SELECT * INTO v_receipt
  FROM henvalt.shopify_privacy_webhook_deliveries r
  WHERE r.id = v_job.receipt_id
  FOR UPDATE;

  v_token := pg_catalog.encode(extensions.gen_random_bytes(32), 'hex');

  UPDATE henvalt.shopify_privacy_processing_jobs_v2 AS j
     SET state = 'CLAIMED',
         attempt_count = j.attempt_count + 1,
         claim_token_sha256 = pg_catalog.encode(
           extensions.digest(pg_catalog.convert_to(v_token, 'UTF8'), 'sha256'), 'hex'
         ),
         claimed_at = pg_catalog.now(),
         lease_until = pg_catalog.now() + pg_catalog.make_interval(secs => p_lease_seconds),
         last_failure_code = NULL,
         updated_at = pg_catalog.now()
   WHERE j.receipt_id = v_job.receipt_id
  RETURNING j.* INTO v_job;

  UPDATE henvalt.shopify_privacy_webhook_deliveries
     SET processing_status = 'PROCESSING',
         failure_code = NULL
   WHERE id = v_receipt.id;

  receipt_id := v_receipt.id;
  claim_token := v_token;
  app_key := v_receipt.app_key;
  tenant_id := v_receipt.tenant_id;
  connection_id := v_receipt.connection_id;
  shop_domain := v_receipt.shop_domain;
  topic := v_receipt.topic;
  customer_id := v_receipt.customer_id;
  request_id := v_receipt.request_id;
  body_sha256 := v_receipt.raw_body_sha256;
  attempt_count := v_job.attempt_count;
  lease_expires_at := v_job.lease_until;
  RETURN NEXT;
END;
$function$;

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
  v_topic text;
BEGIN
  IF p_receipt_id IS NULL
     OR p_claim_token IS NULL
     OR p_claim_token !~ '^[0-9a-f]{64}$'
     OR p_processor_confirmed IS DISTINCT FROM true THEN
    RETURN false;
  END IF;

  SELECT r.topic INTO v_topic
  FROM henvalt.shopify_privacy_webhook_deliveries r
  WHERE r.id = p_receipt_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RETURN false;
  END IF;

  UPDATE henvalt.shopify_privacy_processing_jobs_v2 j
     SET state = 'COMPLETED',
         claim_token_sha256 = NULL,
         lease_until = NULL,
         completed_at = pg_catalog.now(),
         updated_at = pg_catalog.now(),
         last_failure_code = NULL
   WHERE j.receipt_id = p_receipt_id
     AND j.state = 'CLAIMED'
     AND j.lease_until > pg_catalog.now()
     AND j.claim_token_sha256 = pg_catalog.encode(
       extensions.digest(pg_catalog.convert_to(p_claim_token, 'UTF8'), 'sha256'), 'hex'
     );

  IF NOT FOUND THEN
    RETURN false;
  END IF;

  UPDATE henvalt.shopify_privacy_webhook_deliveries
     SET processing_status = 'COMPLETED',
         processed_at = pg_catalog.now(),
         failure_code = NULL,
         customer_id = NULL
   WHERE id = p_receipt_id;

  RETURN true;
END;
$function$;

CREATE OR REPLACE FUNCTION henvalt.fail_shopify_privacy_request_v2(
  p_receipt_id uuid,
  p_claim_token text,
  p_failure_code text,
  p_retryable boolean DEFAULT true
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_state text;
BEGIN
  IF p_receipt_id IS NULL
     OR p_claim_token IS NULL
     OR p_claim_token !~ '^[0-9a-f]{64}$'
     OR p_failure_code IS NULL
     OR p_failure_code !~ '^[A-Z0-9_]{1,64}$'
     OR p_retryable IS NULL THEN
    RETURN false;
  END IF;

  UPDATE henvalt.shopify_privacy_processing_jobs_v2 j
     SET state = CASE WHEN p_retryable AND j.attempt_count < 10
                      THEN 'READY' ELSE 'FAILED' END,
         claim_token_sha256 = NULL,
         lease_until = NULL,
         last_failure_code = p_failure_code,
         updated_at = pg_catalog.now()
   WHERE j.receipt_id = p_receipt_id
     AND j.state = 'CLAIMED'
     AND j.lease_until > pg_catalog.now()
     AND j.claim_token_sha256 = pg_catalog.encode(
       extensions.digest(pg_catalog.convert_to(p_claim_token, 'UTF8'), 'sha256'), 'hex'
     )
  RETURNING j.state INTO v_state;

  IF NOT FOUND THEN
    RETURN false;
  END IF;

  UPDATE henvalt.shopify_privacy_webhook_deliveries
     SET processing_status = CASE WHEN v_state = 'READY'
                                  THEN 'REVIEW_REQUIRED' ELSE 'FAILED' END,
         failure_code = p_failure_code
   WHERE id = p_receipt_id;

  RETURN true;
END;
$function$;

REVOKE ALL ON FUNCTION henvalt.claim_shopify_privacy_request_v2(integer)
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION henvalt.complete_shopify_privacy_request_v2(uuid,text,boolean)
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION henvalt.fail_shopify_privacy_request_v2(uuid,text,text,boolean)
  FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION henvalt.claim_shopify_privacy_request_v2(integer) TO service_role;
GRANT EXECUTE ON FUNCTION henvalt.complete_shopify_privacy_request_v2(uuid,text,boolean) TO service_role;
GRANT EXECUTE ON FUNCTION henvalt.fail_shopify_privacy_request_v2(uuid,text,text,boolean) TO service_role;

COMMENT ON TABLE henvalt.shopify_privacy_processing_jobs_v2 IS
  'Service-only leased queue for verified exact-store Shopify privacy receipts. No export or deletion is performed by the queue itself.';

COMMIT;

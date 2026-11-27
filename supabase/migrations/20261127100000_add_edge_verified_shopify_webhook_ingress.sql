-- Shopify HMAC is verified at the staging Edge Function boundary using the
-- Shopify app secret. This RPC is intentionally executable only by service_role.
-- It accepts only the service-role caller's assertion that HMAC was verified.
CREATE OR REPLACE FUNCTION henvalt.receive_shopify_webhook_edge_verified_v1(
  p_shop_domain text,
  p_topic text,
  p_delivery_id text,
  p_raw_body_base64 text,
  p_payload jsonb,
  p_metadata jsonb DEFAULT '{}'::jsonb
)
RETURNS TABLE(
  http_status integer,
  result_status text,
  tenant_id uuid,
  webhook_id uuid,
  replay_job_id uuid,
  replay_job_status henvalt.job_status,
  is_duplicate boolean,
  should_process boolean,
  processing_status text,
  correlation_id uuid
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_shop_domain text;
  v_tenant_id uuid;
  v_correlation_id uuid;
  v_raw_payload jsonb;
  v_ingest record;
BEGIN
  v_shop_domain := lower(btrim(COALESCE(p_shop_domain, '')));

  IF v_shop_domain !~ '^[a-z0-9][a-z0-9-]*\\.myshopify\\.com$'
     OR NULLIF(btrim(p_topic), '') IS NULL
     OR NULLIF(btrim(p_delivery_id), '') IS NULL
     OR NULLIF(btrim(p_raw_body_base64), '') IS NULL
     OR p_payload IS NULL THEN
    RETURN QUERY SELECT 422, 'malformed_event', NULL::uuid, NULL::uuid, NULL::uuid,
      NULL::henvalt.job_status, NULL::boolean, NULL::boolean, NULL::text, NULL::uuid;
    RETURN;
  END IF;

  BEGIN
    v_raw_payload := convert_from(decode(p_raw_body_base64, 'base64'), 'UTF8')::jsonb;
  EXCEPTION WHEN OTHERS THEN
    RETURN QUERY SELECT 422, 'malformed_event', NULL::uuid, NULL::uuid, NULL::uuid,
      NULL::henvalt.job_status, NULL::boolean, NULL::boolean, NULL::text, NULL::uuid;
    RETURN;
  END;

  IF jsonb_typeof(v_raw_payload) IS DISTINCT FROM 'object'
     OR v_raw_payload IS DISTINCT FROM p_payload THEN
    RETURN QUERY SELECT 422, 'malformed_event', NULL::uuid, NULL::uuid, NULL::uuid,
      NULL::henvalt.job_status, NULL::boolean, NULL::boolean, NULL::text, NULL::uuid;
    RETURN;
  END IF;

  v_tenant_id := henvalt.resolve_shopify_tenant(v_shop_domain);
  IF v_tenant_id IS NULL THEN
    RETURN QUERY SELECT 404, 'unknown_tenant', NULL::uuid, NULL::uuid, NULL::uuid,
      NULL::henvalt.job_status, NULL::boolean, NULL::boolean, NULL::text, NULL::uuid;
    RETURN;
  END IF;

  IF COALESCE(p_metadata->>'correlation_id', '') ~*
     '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' THEN
    v_correlation_id := (p_metadata->>'correlation_id')::uuid;
  ELSE
    v_correlation_id := gen_random_uuid();
  END IF;

  SELECT *
    INTO v_ingest
    FROM henvalt.ingest_shopify_webhook_with_replay_job(
      v_tenant_id,
      'shopify',
      p_delivery_id,
      p_topic,
      'shopify:' || v_shop_domain || ':' || p_delivery_id,
      p_payload,
      COALESCE(p_metadata, '{}'::jsonb) || jsonb_build_object(
        'shop_domain', v_shop_domain,
        'shopify_webhook_id', p_delivery_id,
        'shopify_topic', p_topic,
        'correlation_id', v_correlation_id,
        'ingress_hmac_verified', true,
        'hmac_verifier', 'shopify_edge_function'
      )
    );

  IF NOT FOUND OR v_ingest.webhook_id IS NULL THEN
    RAISE EXCEPTION 'SHOPIFY_WEBHOOK_DURABLE_INGEST_FAILED' USING ERRCODE = '55000';
  END IF;

  IF v_ingest.processing_status = 'PROCESSED' THEN
    RETURN QUERY SELECT 200, 'duplicate', v_tenant_id, v_ingest.webhook_id,
      NULL::uuid, NULL::henvalt.job_status, v_ingest.is_duplicate, false,
      v_ingest.processing_status, v_correlation_id;
    RETURN;
  END IF;

  IF v_ingest.replay_job_id IS NULL OR v_ingest.replay_job_status NOT IN (
    'QUEUED'::henvalt.job_status, 'CLAIMED'::henvalt.job_status,
    'RUNNING'::henvalt.job_status, 'RETRY_WAIT'::henvalt.job_status
  ) THEN
    RAISE EXCEPTION 'SHOPIFY_WEBHOOK_REPLAY_JOB_NOT_ACTIVE' USING ERRCODE = '55000';
  END IF;

  RETURN QUERY SELECT 200,
    CASE WHEN v_ingest.is_duplicate THEN 'replay_accepted' ELSE 'accepted' END,
    v_tenant_id, v_ingest.webhook_id, v_ingest.replay_job_id,
    v_ingest.replay_job_status, v_ingest.is_duplicate, v_ingest.should_process,
    v_ingest.processing_status, v_correlation_id;
END;
$function$;

REVOKE ALL ON FUNCTION henvalt.receive_shopify_webhook_edge_verified_v1(text,text,text,text,jsonb,jsonb) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION henvalt.receive_shopify_webhook_edge_verified_v1(text,text,text,text,jsonb,jsonb) TO service_role;

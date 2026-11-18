-- HENVALT connection-aware Shopify Web Pixel V2 intake inbox.
-- PREPARATION ONLY. Depends on migration 007 exact-store core lineage.
-- This stage deliberately stops at a server-only inbox: it does not create
-- canonical events, customers, sessions, aliases, checkouts, or recovery work.
-- A separate adapter is gated until every downstream reader/writer is store-aware.

BEGIN;

CREATE TABLE IF NOT EXISTS henvalt.shopify_pixel_event_inbox_v2 (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id uuid NOT NULL,
  shopify_connection_id uuid NOT NULL,
  source_event_id text NOT NULL,
  event_type text NOT NULL CHECK (
    event_type IN (
      'page_viewed',
      'product_viewed',
      'product_added_to_cart',
      'product_removed_from_cart',
      'checkout_started'
    )
  ),
  event_digest text NOT NULL CHECK (event_digest ~ '^[0-9a-f]{64}$'),
  occurred_at timestamptz NOT NULL,
  analytics_processing_allowed boolean NOT NULL,
  marketing_allowed boolean NOT NULL,
  client_reference text,
  customer_reference text,
  checkout_reference text,
  payload jsonb NOT NULL DEFAULT '{}'::jsonb,
  status text NOT NULL DEFAULT 'PENDING_ADAPTER'
    CHECK (status IN ('PENDING_ADAPTER', 'ACCEPTED', 'REJECTED', 'PROCESSED')),
  received_at timestamptz NOT NULL DEFAULT now(),
  processed_at timestamptz,
  CONSTRAINT shopify_pixel_event_inbox_v2_connection_tenant_fkey
    FOREIGN KEY (shopify_connection_id, tenant_id)
    REFERENCES henvalt.shopify_connections (id, tenant_id)
    ON UPDATE RESTRICT ON DELETE RESTRICT,
  CONSTRAINT shopify_pixel_event_inbox_v2_connection_event_uidx
    UNIQUE (shopify_connection_id, source_event_id)
);

CREATE INDEX IF NOT EXISTS shopify_pixel_event_inbox_v2_pending_idx
  ON henvalt.shopify_pixel_event_inbox_v2 (status, received_at)
  WHERE status = 'PENDING_ADAPTER';

ALTER TABLE henvalt.shopify_pixel_event_inbox_v2 ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON henvalt.shopify_pixel_event_inbox_v2 FROM PUBLIC, anon, authenticated, service_role;

COMMENT ON TABLE henvalt.shopify_pixel_event_inbox_v2 IS
  'Server-only, exact-install Web Pixel V2 inbox. Pending rows are intentionally excluded from canonical events and all recovery, delivery, attribution and billing flows until a separately approved store-aware adapter exists.';
COMMENT ON COLUMN henvalt.shopify_pixel_event_inbox_v2.client_reference IS
  'Pseudonymous storefront client reference; populated only when analytics consent is true.';
COMMENT ON COLUMN henvalt.shopify_pixel_event_inbox_v2.customer_reference IS
  'Shopify customer reference; populated only when analytics consent is true. Never use as a tenant-wide identity key.';
COMMENT ON COLUMN henvalt.shopify_pixel_event_inbox_v2.checkout_reference IS
  'Checkout alias; populated only when analytics consent is true. Must be scoped to this connection by any future adapter.';

CREATE OR REPLACE FUNCTION henvalt.ingest_pixel_event_v2(
  p_key_digest text,
  p_origin text,
  p_payload jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_tenant_id uuid;
  v_connection_id uuid;
  v_event_type text;
  v_event_id text;
  v_client_id text;
  v_customer_reference text;
  v_checkout_reference text;
  v_analytics_allowed boolean;
  v_marketing_allowed boolean;
  v_occurred_at timestamptz;
  v_request_count integer;
  v_bucket timestamptz;
  v_event_digest text;
  v_safe_payload jsonb;
  v_inbox_id uuid;
  v_existing_digest text;
BEGIN
  IF p_key_digest IS NULL
     OR p_key_digest !~ '^[0-9a-f]{64}$'
     OR p_origin IS NULL
     OR length(p_origin) > 500
     OR p_origin NOT LIKE 'https://%'
     OR p_payload IS NULL
     OR jsonb_typeof(p_payload) <> 'object'
     OR octet_length(p_payload::text) > 12000 THEN
    RAISE EXCEPTION 'Invalid pixel event request';
  END IF;

  v_event_type := p_payload->>'event_type';
  v_event_id := p_payload->>'event_id';
  v_client_id := p_payload->>'client_id';
  v_analytics_allowed := p_payload->>'analytics_consent' = 'true';
  v_marketing_allowed := p_payload->>'marketing_consent' = 'true';

  IF coalesce(p_payload->>'schema_version', '') <> '1'
     OR v_event_type IS NULL
     OR v_event_type NOT IN (
       'page_viewed',
       'product_viewed',
       'product_added_to_cart',
       'product_removed_from_cart',
       'checkout_started'
     )
     OR v_event_id IS NULL
     OR length(v_event_id) < 1
     OR length(v_event_id) > 160
     OR v_client_id IS NULL
     OR length(v_client_id) < 1
     OR length(v_client_id) > 160 THEN
    RAISE EXCEPTION 'Pixel event failed validation';
  END IF;

  v_customer_reference := CASE
    WHEN v_analytics_allowed
      THEN nullif(btrim(p_payload->>'customer_reference'), '')
    ELSE NULL
  END;

  v_checkout_reference := CASE
    WHEN v_analytics_allowed AND v_event_type = 'checkout_started'
      THEN nullif(btrim(p_payload->>'checkout_reference'), '')
    ELSE NULL
  END;

  IF (v_customer_reference IS NOT NULL AND length(v_customer_reference) > 200)
     OR (v_checkout_reference IS NOT NULL AND length(v_checkout_reference) > 300) THEN
    RAISE EXCEPTION 'Pixel event failed validation';
  END IF;

  BEGIN
    v_occurred_at := coalesce(nullif(p_payload->>'occurred_at', '')::timestamptz, now());
  EXCEPTION WHEN others THEN
    v_occurred_at := now();
  END;

  IF v_occurred_at > now() + interval '5 minutes'
     OR v_occurred_at < now() - interval '90 days' THEN
    v_occurred_at := now();
  END IF;

  -- The authoritative tenant and connection come only from the active,
  -- origin-bound pixel key. Browser-supplied IDs are never accepted.
  SELECT pk.tenant_id, pk.shopify_connection_id
    INTO v_tenant_id, v_connection_id
  FROM henvalt.pixel_keys pk
  JOIN henvalt.shopify_connections sc
    ON sc.id = pk.shopify_connection_id
   AND sc.tenant_id = pk.tenant_id
   AND sc.active = true
  JOIN henvalt.tenants t
    ON t.id = pk.tenant_id
   AND t.status = 'ACTIVE'
  WHERE pk.key_digest = p_key_digest
    AND pk.active = true
    AND pk.revoked_at IS NULL
    AND p_origin = ANY(pk.allowed_origins)
  LIMIT 1;

  IF v_tenant_id IS NULL OR v_connection_id IS NULL THEN
    RAISE EXCEPTION 'Pixel key, shop connection, or origin is not authorized';
  END IF;

  v_bucket := date_trunc('minute', now());
  INSERT INTO henvalt.pixel_rate_limits (key_digest, bucket_start, request_count)
  VALUES (p_key_digest, v_bucket, 1)
  ON CONFLICT (key_digest)
  DO UPDATE SET
    request_count = CASE
      WHEN henvalt.pixel_rate_limits.bucket_start = EXCLUDED.bucket_start
        THEN henvalt.pixel_rate_limits.request_count + 1
      ELSE 1
    END,
    bucket_start = EXCLUDED.bucket_start
  RETURNING request_count INTO v_request_count;

  IF v_request_count > 120 THEN
    RETURN jsonb_build_object('accepted', false, 'error', 'rate_limited');
  END IF;

  v_event_digest := encode(
    extensions.digest(convert_to(p_payload::text, 'UTF8'), 'sha256'),
    'hex'
  );

  -- No identity-bearing storefront fields are persisted without analytics
  -- consent. Marketing consent is recorded separately and never implies
  -- analytics consent.
  v_safe_payload := jsonb_build_object(
    'schema_version', '1',
    'event_type', v_event_type,
    'occurred_at', v_occurred_at,
    'analytics_consent', v_analytics_allowed,
    'marketing_consent', v_marketing_allowed
  );

  IF v_analytics_allowed THEN
    v_safe_payload := v_safe_payload || jsonb_build_object(
      'client_id', v_client_id,
      'customer_reference', v_customer_reference,
      'checkout_reference', v_checkout_reference,
      'product', CASE WHEN jsonb_typeof(p_payload->'product') = 'object' THEN
        jsonb_strip_nulls(jsonb_build_object(
          'id', CASE WHEN length(p_payload #>> '{product,id}') BETWEEN 1 AND 200 THEN p_payload #>> '{product,id}' END,
          'title', CASE WHEN length(p_payload #>> '{product,title}') BETWEEN 1 AND 200 THEN p_payload #>> '{product,title}' END,
          'variant_id', CASE WHEN length(p_payload #>> '{product,variant_id}') BETWEEN 1 AND 200 THEN p_payload #>> '{product,variant_id}' END,
          'price_amount', CASE WHEN length(coalesce(p_payload #>> '{product,price_amount}','')) BETWEEN 1 AND 17 AND translate(p_payload #>> '{product,price_amount}', '0123456789.', '') = '' AND length(p_payload #>> '{product,price_amount}') - length(replace(p_payload #>> '{product,price_amount}', '.', '')) <= 1 AND left(p_payload #>> '{product,price_amount}', 1) <> '.' AND right(p_payload #>> '{product,price_amount}', 1) <> '.' THEN p_payload #>> '{product,price_amount}' END,
          'price_currency', CASE WHEN length(coalesce(p_payload #>> '{product,price_currency}','')) = 3 AND translate(upper(p_payload #>> '{product,price_currency}'), 'ABCDEFGHIJKLMNOPQRSTUVWXYZ', '') = '' THEN upper(p_payload #>> '{product,price_currency}') END
        )) ELSE '{}'::jsonb END,
      'cart_line', CASE WHEN jsonb_typeof(p_payload->'cart_line') = 'object' THEN
        jsonb_strip_nulls(jsonb_build_object(
          'quantity', CASE WHEN length(coalesce(p_payload #>> '{cart_line,quantity}','')) BETWEEN 1 AND 3 AND translate(p_payload #>> '{cart_line,quantity}', '0123456789', '') = '' AND (p_payload #>> '{cart_line,quantity}')::integer BETWEEN 0 AND 999 THEN (p_payload #>> '{cart_line,quantity}')::integer END,
          'merchandise_id', CASE WHEN length(p_payload #>> '{cart_line,merchandise_id}') BETWEEN 1 AND 200 THEN p_payload #>> '{cart_line,merchandise_id}' END,
          'product_id', CASE WHEN length(p_payload #>> '{cart_line,product_id}') BETWEEN 1 AND 200 THEN p_payload #>> '{cart_line,product_id}' END,
          'product_title', CASE WHEN length(p_payload #>> '{cart_line,product_title}') BETWEEN 1 AND 200 THEN p_payload #>> '{cart_line,product_title}' END,
          'variant_title', CASE WHEN length(p_payload #>> '{cart_line,variant_title}') BETWEEN 1 AND 200 THEN p_payload #>> '{cart_line,variant_title}' END,
          'unit_price_amount', CASE WHEN length(coalesce(p_payload #>> '{cart_line,unit_price_amount}','')) BETWEEN 1 AND 17 AND translate(p_payload #>> '{cart_line,unit_price_amount}', '0123456789.', '') = '' AND length(p_payload #>> '{cart_line,unit_price_amount}') - length(replace(p_payload #>> '{cart_line,unit_price_amount}', '.', '')) <= 1 AND left(p_payload #>> '{cart_line,unit_price_amount}', 1) <> '.' AND right(p_payload #>> '{cart_line,unit_price_amount}', 1) <> '.' THEN p_payload #>> '{cart_line,unit_price_amount}' END,
          'line_total_amount', CASE WHEN length(coalesce(p_payload #>> '{cart_line,line_total_amount}','')) BETWEEN 1 AND 17 AND translate(p_payload #>> '{cart_line,line_total_amount}', '0123456789.', '') = '' AND length(p_payload #>> '{cart_line,line_total_amount}') - length(replace(p_payload #>> '{cart_line,line_total_amount}', '.', '')) <= 1 AND left(p_payload #>> '{cart_line,line_total_amount}', 1) <> '.' AND right(p_payload #>> '{cart_line,line_total_amount}', 1) <> '.' THEN p_payload #>> '{cart_line,line_total_amount}' END,
          'currency', CASE WHEN length(coalesce(p_payload #>> '{cart_line,currency}','')) = 3 AND translate(upper(p_payload #>> '{cart_line,currency}'), 'ABCDEFGHIJKLMNOPQRSTUVWXYZ', '') = '' THEN upper(p_payload #>> '{cart_line,currency}') END
        )) ELSE '{}'::jsonb END
    );
  END IF;

  INSERT INTO henvalt.shopify_pixel_event_inbox_v2 (
    tenant_id,
    shopify_connection_id,
    source_event_id,
    event_type,
    event_digest,
    occurred_at,
    analytics_processing_allowed,
    marketing_allowed,
    client_reference,
    customer_reference,
    checkout_reference,
    payload
  )
  VALUES (
    v_tenant_id,
    v_connection_id,
    v_event_id,
    v_event_type,
    v_event_digest,
    v_occurred_at,
    v_analytics_allowed,
    v_marketing_allowed,
    CASE WHEN v_analytics_allowed THEN v_client_id ELSE NULL END,
    v_customer_reference,
    v_checkout_reference,
    v_safe_payload
  )
  ON CONFLICT (shopify_connection_id, source_event_id) DO NOTHING
  RETURNING id INTO v_inbox_id;

  IF v_inbox_id IS NOT NULL THEN
    RETURN jsonb_build_object(
      'accepted', true,
      'duplicate', false,
      'status', 'PENDING_ADAPTER',
      'inbox_id', v_inbox_id
    );
  END IF;

  SELECT id, event_digest
    INTO v_inbox_id, v_existing_digest
  FROM henvalt.shopify_pixel_event_inbox_v2
  WHERE shopify_connection_id = v_connection_id
    AND source_event_id = v_event_id;

  IF v_existing_digest IS DISTINCT FROM v_event_digest THEN
    RETURN jsonb_build_object(
      'accepted', false,
      'duplicate', false,
      'rejection_code', 'EVENT_ID_BODY_MISMATCH'
    );
  END IF;

  RETURN jsonb_build_object(
    'accepted', true,
    'duplicate', true,
    'status', 'PENDING_ADAPTER',
    'inbox_id', v_inbox_id
  );
END;
$function$;

REVOKE ALL ON FUNCTION henvalt.ingest_pixel_event_v2(text, text, jsonb)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION henvalt.ingest_pixel_event_v2(text, text, jsonb)
  TO service_role;

COMMIT;

-- Enforce storefront analytics consent at the server boundary and require
-- Shopify privacy marketing permission before creating browse-recovery candidates.
-- Candidate migration only; do not apply to production without approved staging tests.

BEGIN;

CREATE OR REPLACE FUNCTION henvalt.ingest_pixel_event(
  p_key_digest text,
  p_origin text,
  p_payload jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'henvalt', 'public'
AS $function$
DECLARE
  v_tenant_id uuid;
  v_event_id uuid;
  v_duplicate boolean;
  v_event_type text;
  v_event_source_id text;
  v_client_id text;
  v_customer_reference text;
  v_checkout_reference text;
  v_analytics_allowed boolean;
  v_bucket timestamptz;
  v_request_count integer;
  v_occurred_at timestamptz;
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

  -- Do not persist anything from a storefront event unless analytics consent
  -- was explicitly true at collection time. Reject before rate-limit or event writes.
  v_analytics_allowed := p_payload->>'analytics_consent' = 'true';
  IF NOT v_analytics_allowed THEN
    RETURN jsonb_build_object(
      'accepted', false,
      'error', 'analytics_consent_required'
    );
  END IF;

  v_event_type := p_payload->>'event_type';
  v_event_source_id := p_payload->>'event_id';
  v_client_id := p_payload->>'client_id';
  v_customer_reference := nullif(btrim(p_payload->>'customer_reference'), '');
  v_checkout_reference := CASE
    WHEN v_event_type = 'checkout_started'
      THEN nullif(btrim(p_payload->>'checkout_reference'), '')
    ELSE NULL
  END;

  IF coalesce(p_payload->>'schema_version', '') <> '1'
     OR v_event_type IS NULL
     OR v_event_type NOT IN (
       'page_viewed',
       'product_viewed',
       'product_added_to_cart',
       'product_removed_from_cart',
       'checkout_started'
     )
     OR v_event_source_id IS NULL
     OR length(v_event_source_id) < 1
     OR length(v_event_source_id) > 160
     OR v_client_id IS NULL
     OR length(v_client_id) < 1
     OR length(v_client_id) > 160
     OR (v_customer_reference IS NOT NULL AND length(v_customer_reference) > 200)
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

  SELECT pk.tenant_id
    INTO v_tenant_id
  FROM henvalt.pixel_keys pk
  JOIN henvalt.shopify_connections sc
    ON sc.id = pk.shopify_connection_id
   AND sc.tenant_id = pk.tenant_id
   AND sc.active = true
  JOIN henvalt.tenants t
    ON t.id = pk.tenant_id
  WHERE pk.key_digest = p_key_digest
    AND pk.active = true
    AND pk.revoked_at IS NULL
    AND p_origin = ANY(pk.allowed_origins)
    AND t.status = 'ACTIVE'
  LIMIT 1;

  IF v_tenant_id IS NULL THEN
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

  SELECT ue.event_id, ue.is_duplicate
    INTO v_event_id, v_duplicate
  FROM henvalt.upsert_canonical_event(
    v_tenant_id,
    NULL,
    upper(v_event_type),
    'OTHER'::henvalt.event_class,
    'SHOPIFY_WEB_PIXEL',
    v_event_source_id,
    v_customer_reference,
    NULL,
    NULL,
    v_client_id,
    v_occurred_at,
    NULL,
    NULL,
    p_payload - 'public_key',
    jsonb_build_object(
      'collector_version', 1,
      'consent_context', 'shopify_pixel_customer_privacy',
      'analytics_processing_allowed', true,
      'marketing_allowed', p_payload->>'marketing_consent' = 'true'
    ),
    'shopify-pixel:' || v_event_source_id,
    NULL
  ) ue;

  PERFORM henvalt.resolve_identity(v_event_id);

  IF v_checkout_reference IS NOT NULL THEN
    PERFORM henvalt.bind_session_alias(v_tenant_id, v_checkout_reference, v_client_id);
  END IF;

  RETURN jsonb_build_object(
    'accepted', true,
    'duplicate', coalesce(v_duplicate, false),
    'event_id', v_event_id
  );
END;
$function$;

CREATE OR REPLACE FUNCTION henvalt.get_browse_abandonment_candidates(
  p_inactivity_minutes integer DEFAULT 60,
  p_max_age_hours integer DEFAULT 24,
  p_limit integer DEFAULT 100
)
RETURNS TABLE(
  tenant_id uuid,
  customer_id uuid,
  session_reference text,
  product_id text,
  product_title text,
  variant_id text,
  price_amount numeric,
  currency character,
  destination_url text,
  source_event_id uuid,
  last_activity_at timestamptz,
  shop_domain text
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO 'henvalt', 'public'
AS $function$
  WITH product_events AS (
    SELECT
      e.id AS source_event_id,
      e.tenant_id,
      e.customer_reference,
      e.session_reference,
      e.occurred_at,
      e.payload,
      c.id AS customer_id,
      c.email,
      c.email_consent,
      sc.shop_domain,
      NULLIF(e.payload #>> '{product,id}', '') AS product_id,
      NULLIF(e.payload #>> '{product,title}', '') AS product_title,
      NULLIF(e.payload #>> '{product,variant_id}', '') AS variant_id,
      CASE
        WHEN coalesce(e.payload #>> '{product,price_amount}', '') ~ '^[0-9]+(\\.[0-9]+)?$'
          THEN (e.payload #>> '{product,price_amount}')::numeric
        ELSE NULL
      END AS price_amount,
      CASE
        WHEN upper(coalesce(e.payload #>> '{product,price_currency}', '')) ~ '^[A-Z]{3}$'
          THEN upper(e.payload #>> '{product,price_currency}')::character(3)
        ELSE NULL
      END AS currency,
      NULLIF(e.payload->>'page_url', '') AS destination_url
    FROM henvalt.canonical_events e
    JOIN henvalt.customers c
      ON c.tenant_id = e.tenant_id
     AND c.shopify_customer_id = e.customer_reference
    JOIN henvalt.shopify_connections sc
      ON sc.tenant_id = e.tenant_id
     AND sc.active = true
    WHERE e.source = 'SHOPIFY_WEB_PIXEL'
      AND upper(e.event_type) = 'PRODUCT_VIEWED'
      AND e.customer_reference IS NOT NULL
      AND e.session_reference IS NOT NULL
      AND e.payload->>'analytics_consent' = 'true'
      AND e.metadata->>'marketing_allowed' = 'true'
      AND c.email IS NOT NULL
      AND c.email_consent IS TRUE
      AND e.occurred_at >= now() - make_interval(
        hours => greatest(1, least(coalesce(p_max_age_hours, 24), 168))
      )
  ),
  ranked AS (
    SELECT
      pe.*,
      (
        SELECT max(e2.occurred_at)
        FROM henvalt.canonical_events e2
        WHERE e2.tenant_id = pe.tenant_id
          AND e2.source = 'SHOPIFY_WEB_PIXEL'
          AND e2.session_reference = pe.session_reference
          AND e2.occurred_at >= pe.occurred_at
      ) AS last_activity_at,
      row_number() OVER (
        PARTITION BY pe.tenant_id, pe.session_reference, pe.product_id
        ORDER BY pe.occurred_at DESC
      ) AS product_rank
    FROM product_events pe
  )
  SELECT
    r.tenant_id,
    r.customer_id,
    r.session_reference,
    r.product_id,
    r.product_title,
    r.variant_id,
    r.price_amount,
    r.currency,
    r.destination_url,
    r.source_event_id,
    r.last_activity_at,
    r.shop_domain
  FROM ranked r
  WHERE r.product_rank = 1
    AND r.product_id IS NOT NULL
    AND r.product_title IS NOT NULL
    AND r.price_amount IS NOT NULL
    AND r.price_amount > 0
    AND r.currency IS NOT NULL
    AND r.destination_url LIKE 'https://%'
    AND r.last_activity_at <= now() - make_interval(
      mins => greatest(30, least(coalesce(p_inactivity_minutes, 60), 1440))
    )
    AND r.last_activity_at >= now() - make_interval(
      hours => greatest(1, least(coalesce(p_max_age_hours, 24), 168))
    )
    AND NOT EXISTS (
      SELECT 1
      FROM henvalt.canonical_events later
      WHERE later.tenant_id = r.tenant_id
        AND later.source = 'SHOPIFY_WEB_PIXEL'
        AND later.session_reference = r.session_reference
        AND later.occurred_at > r.occurred_at
        AND upper(later.event_type) IN ('PRODUCT_ADDED_TO_CART', 'CHECKOUT_STARTED')
    )
    AND NOT EXISTS (
      SELECT 1
      FROM henvalt.checkouts ck
      WHERE ck.tenant_id = r.tenant_id
        AND (
          ck.session_reference = r.session_reference
          OR EXISTS (
            SELECT 1
            FROM henvalt.session_aliases sa
            WHERE sa.tenant_id = ck.tenant_id
              AND sa.alias_reference = ck.metadata->>'cart_token'
              AND sa.session_reference = r.session_reference
          )
        )
        AND greatest(ck.created_at, ck.updated_at) >= r.occurred_at
    )
    AND (
      SELECT count(*)
      FROM henvalt.canonical_events repeat_view
      WHERE repeat_view.tenant_id = r.tenant_id
        AND repeat_view.source = 'SHOPIFY_WEB_PIXEL'
        AND upper(repeat_view.event_type) = 'PRODUCT_VIEWED'
        AND repeat_view.session_reference = r.session_reference
        AND repeat_view.payload #>> '{product,id}' = r.product_id
        AND repeat_view.occurred_at >= now() - make_interval(
          hours => greatest(1, least(coalesce(p_max_age_hours, 24), 168))
        )
    ) >= 2
  ORDER BY r.last_activity_at ASC
  LIMIT greatest(1, least(coalesce(p_limit, 100), 500));
$function$;

COMMIT;

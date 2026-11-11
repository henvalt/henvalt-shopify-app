CREATE OR REPLACE FUNCTION henvalt.get_browse_abandonment_candidates(
  p_inactivity_minutes integer DEFAULT 60,
  p_max_age_hours integer DEFAULT 24,
  p_limit integer DEFAULT 100
)
RETURNS TABLE(
  tenant_id uuid, customer_id uuid, session_reference text,
  product_id text, product_title text, variant_id text,
  price_amount numeric, currency character, destination_url text,
  source_event_id uuid, last_activity_at timestamptz, shop_domain text
)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path TO 'henvalt', 'public'
AS $function$
  WITH product_events AS (
    SELECT e.id AS source_event_id, e.tenant_id, e.customer_reference,
      e.session_reference, e.occurred_at, e.payload,
      c.id AS customer_id, c.email, c.email_consent, sc.shop_domain,
      NULLIF(e.payload #>> '{product,id}','') AS product_id,
      NULLIF(e.payload #>> '{product,title}','') AS product_title,
      NULLIF(e.payload #>> '{product,variant_id}','') AS variant_id,
      CASE WHEN coalesce(e.payload #>> '{product,price_amount}','') ~ '^[0-9]+(\.[0-9]+)?$'
        THEN (e.payload #>> '{product,price_amount}')::numeric ELSE NULL END AS price_amount,
      CASE WHEN upper(coalesce(e.payload #>> '{product,price_currency}','')) ~ '^[A-Z]{3}$'
        THEN upper(e.payload #>> '{product,price_currency}')::character(3) ELSE NULL END AS currency,
      NULLIF(e.payload->>'page_url','') AS destination_url
    FROM henvalt.canonical_events e
    JOIN henvalt.customers c ON c.tenant_id=e.tenant_id
      AND c.shopify_customer_id=e.customer_reference
    JOIN henvalt.shopify_connections sc ON sc.tenant_id=e.tenant_id AND sc.active=true
    WHERE e.source='SHOPIFY_WEB_PIXEL'
      AND upper(e.event_type)='PRODUCT_VIEWED'
      AND e.customer_reference IS NOT NULL
      AND e.session_reference IS NOT NULL
      AND e.payload->>'analytics_consent'='true'
      AND e.payload->>'marketing_consent'='true'
      AND c.email IS NOT NULL AND c.email_consent IS TRUE
      AND e.occurred_at >= now() - make_interval(hours => greatest(1,least(coalesce(p_max_age_hours,24),168)))
  ),
  ranked AS (
    SELECT pe.*,
      (SELECT max(e2.occurred_at) FROM henvalt.canonical_events e2
       WHERE e2.tenant_id=pe.tenant_id AND e2.source='SHOPIFY_WEB_PIXEL'
         AND e2.session_reference=pe.session_reference AND e2.occurred_at>=pe.occurred_at) AS last_activity_at,
      row_number() over (partition by pe.tenant_id,pe.session_reference,pe.product_id
        order by pe.occurred_at desc) AS product_rank
    FROM product_events pe
  )
  SELECT r.tenant_id,r.customer_id,r.session_reference,r.product_id,r.product_title,
    r.variant_id,r.price_amount,r.currency,r.destination_url,r.source_event_id,
    r.last_activity_at,r.shop_domain
  FROM ranked r
  WHERE r.product_rank=1 AND r.product_id IS NOT NULL AND r.product_title IS NOT NULL
    AND r.price_amount IS NOT NULL AND r.price_amount>0 AND r.currency IS NOT NULL
    AND r.destination_url LIKE 'https://%'
    AND r.last_activity_at <= now()-make_interval(mins=>greatest(30,least(coalesce(p_inactivity_minutes,60),1440)))
    AND r.last_activity_at >= now()-make_interval(hours=>greatest(1,least(coalesce(p_max_age_hours,24),168)))
    AND NOT EXISTS (
      SELECT 1 FROM henvalt.canonical_events later
      WHERE later.tenant_id=r.tenant_id AND later.source='SHOPIFY_WEB_PIXEL'
        AND later.session_reference=r.session_reference AND later.occurred_at>r.occurred_at
        AND upper(later.event_type) IN ('PRODUCT_ADDED_TO_CART','CHECKOUT_STARTED')
    )
    AND NOT EXISTS (
      SELECT 1 FROM henvalt.checkouts ck
      WHERE ck.tenant_id=r.tenant_id AND ck.session_reference=r.session_reference
        AND ck.created_at>=r.occurred_at
    )
  ORDER BY r.last_activity_at ASC
  LIMIT greatest(1,least(coalesce(p_limit,100),500));
$function$;

REVOKE ALL ON FUNCTION henvalt.get_browse_abandonment_candidates(integer,integer,integer) FROM PUBLIC, anon, authenticated;

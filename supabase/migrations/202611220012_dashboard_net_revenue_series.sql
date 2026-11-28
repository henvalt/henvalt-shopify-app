-- Revenue series must reflect confirmed recovery revenue net of refund/cancellation adjustments.
-- Candidate migration only; isolated staging acceptance required.
BEGIN;

CREATE OR REPLACE FUNCTION henvalt.control_plane_revenue_series(p_shop_domain text, p_from timestamp with time zone, p_to timestamp with time zone, p_granularity text DEFAULT 'day'::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'henvalt', 'public', 'pg_temp'
AS $function$
DECLARE
  v_shop text := lower(trim(p_shop_domain));
  v_tenant_id uuid;
  v_days integer;
  v_previous_from timestamptz;
  v_previous_revenue numeric := 0;
  v_current_revenue numeric := 0;
  v_change_percent numeric;
  v_step interval;
  v_series jsonb;
BEGIN
  IF p_from IS NULL OR p_to IS NULL OR p_to < p_from
     OR p_to - p_from > interval '366 days'
     OR p_granularity NOT IN ('day', 'week', 'month') THEN
    RAISE EXCEPTION 'invalid_revenue_series_request';
  END IF;

  SELECT sc.tenant_id
    INTO v_tenant_id
  FROM shopify_connections sc
  JOIN tenants t ON t.id = sc.tenant_id
  WHERE sc.shop_domain = v_shop
    AND sc.active = true
    AND t.status = 'ACTIVE'
  LIMIT 1;

  IF v_tenant_id IS NULL THEN
    RAISE EXCEPTION 'active_shop_connection_required';
  END IF;

  v_days := (p_to::date - p_from::date) + 1;
  v_previous_from := p_from - make_interval(days => v_days);
  v_step := CASE p_granularity
    WHEN 'week' THEN interval '1 week'
    WHEN 'month' THEN interval '1 month'
    ELSE interval '1 day'
  END;

  SELECT COALESCE(SUM(rl.amount), 0)
    INTO v_current_revenue
  FROM revenue_ledger rl
  WHERE rl.tenant_id = v_tenant_id
    AND rl.entry_type IN ('RECOVERY', 'ADJUSTMENT') AND rl.billable IS TRUE AND rl.attribution_confidence = 'CONFIRMED'
    AND rl.created_at >= p_from
    AND rl.created_at < p_to + interval '1 day';

  SELECT COALESCE(SUM(rl.amount), 0)
    INTO v_previous_revenue
  FROM revenue_ledger rl
  WHERE rl.tenant_id = v_tenant_id
    AND rl.entry_type IN ('RECOVERY', 'ADJUSTMENT') AND rl.billable IS TRUE AND rl.attribution_confidence = 'CONFIRMED'
    AND rl.created_at >= v_previous_from
    AND rl.created_at < p_from;

  v_change_percent := CASE
    WHEN v_previous_revenue <> 0
      THEN round(((v_current_revenue - v_previous_revenue) / abs(v_previous_revenue)) * 100, 2)
    ELSE NULL
  END;

  WITH buckets AS (
    SELECT generate_series(
      date_trunc(p_granularity, p_from),
      date_trunc(p_granularity, p_to),
      v_step
    ) AS bucket
  ),
  totals AS (
    SELECT date_trunc(p_granularity, rl.created_at) AS bucket,
           SUM(rl.amount) AS revenue
    FROM revenue_ledger rl
    WHERE rl.tenant_id = v_tenant_id
      AND rl.entry_type IN ('RECOVERY', 'ADJUSTMENT') AND rl.billable IS TRUE AND rl.attribution_confidence = 'CONFIRMED'
      AND rl.created_at >= p_from
      AND rl.created_at < p_to + interval '1 day'
    GROUP BY 1
  )
  SELECT COALESCE(
    jsonb_agg(
      jsonb_build_object(
        'bucket', b.bucket,
        'recovered_revenue', COALESCE(t.revenue, 0)
      )
      ORDER BY b.bucket
    ),
    '[]'::jsonb
  )
  INTO v_series
  FROM buckets b
  LEFT JOIN totals t USING (bucket);

  RETURN jsonb_build_object(
    'series', v_series,
    'current_revenue', v_current_revenue,
    'previous_revenue', v_previous_revenue,
    'change_percent', v_change_percent,
    'previous_from', v_previous_from,
    'previous_to', p_from - interval '1 day'
  );
END;
$function$;

COMMIT;

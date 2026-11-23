-- Make dashboard recovered-order counts attribution-consistent and prevent cross-currency sums.
-- Candidate migration only; do not apply to production without explicit release approval.
BEGIN;

CREATE OR REPLACE FUNCTION henvalt.control_plane_dashboard_summary(
  p_shop_domain text,
  p_from timestamptz,
  p_to timestamptz
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO pg_catalog, henvalt, public, pg_temp
AS $function$
DECLARE
  v_shop text := lower(btrim(p_shop_domain));
  v_conn henvalt.shopify_connections%ROWTYPE;
  v_tenant henvalt.tenants%ROWTYPE;
  v_opportunities bigint;
  v_messages bigint;
  v_recovered bigint;
  v_revenue numeric;
  v_currency text;
  v_currency_count integer := 0;
  v_single_currency text;
  v_currency_conflict boolean := false;
  v_revenue_by_currency jsonb := '[]'::jsonb;
  v_activity jsonb;
  v_by_event jsonb;
BEGIN
  SELECT * INTO v_conn
    FROM henvalt.shopify_connections
   WHERE shop_domain = v_shop
     AND active IS TRUE
   LIMIT 1;
  IF NOT FOUND THEN RETURN jsonb_build_object('linked', false); END IF;

  SELECT * INTO v_tenant
    FROM henvalt.tenants
   WHERE id = v_conn.tenant_id
     AND status = 'ACTIVE';
  IF NOT FOUND THEN RETURN jsonb_build_object('linked', false); END IF;

  IF p_from IS NULL OR p_to IS NULL OR p_to < p_from
     OR p_to - p_from > interval '366 days' THEN
    RAISE EXCEPTION 'invalid_date_range';
  END IF;

  SELECT count(*) INTO v_opportunities
    FROM henvalt.opportunities o
   WHERE o.tenant_id = v_tenant.id
     AND o.created_at >= p_from
     AND o.created_at < p_to + interval '1 day';

  SELECT count(*) INTO v_messages
    FROM henvalt.recovery_interventions ri
   WHERE ri.tenant_id = v_tenant.id
     AND ri.status IN ('SENT', 'DELIVERED')
     AND coalesce(ri.sent_at, ri.delivered_at, ri.updated_at) >= p_from
     AND coalesce(ri.sent_at, ri.delivered_at, ri.updated_at) < p_to + interval '1 day';

  -- A recovered order is a confirmed attribution, not merely an opportunity
  -- whose mutable workflow status happens to be RECOVERED.
  SELECT count(DISTINCT oa.order_id) INTO v_recovered
    FROM henvalt.order_attributions oa
   WHERE oa.tenant_id = v_tenant.id
     AND oa.evaluated_at >= p_from
     AND oa.evaluated_at < p_to + interval '1 day'
     AND oa.attribution_confidence = 'CONFIRMED';

  SELECT count(DISTINCT upper(btrim(rl.currency::text)))::integer,
         max(upper(btrim(rl.currency::text)))
    INTO v_currency_count, v_single_currency
    FROM henvalt.revenue_ledger rl
   WHERE rl.tenant_id = v_tenant.id
     AND rl.entry_type = 'RECOVERY'
     AND rl.billable IS TRUE
     AND rl.attribution_confidence = 'CONFIRMED'
     AND rl.created_at >= p_from
     AND rl.created_at < p_to + interval '1 day';

  v_currency_conflict := v_currency_count > 1;
  v_currency := CASE
    WHEN v_currency_count = 1 THEN v_single_currency
    ELSE coalesce(nullif(btrim(v_tenant.default_currency::text), ''), 'USD')
  END;

  IF v_currency_conflict THEN
    v_revenue := NULL;
  ELSE
    SELECT coalesce(sum(rl.amount), 0) INTO v_revenue
      FROM henvalt.revenue_ledger rl
     WHERE rl.tenant_id = v_tenant.id
       AND rl.entry_type = 'RECOVERY'
       AND rl.billable IS TRUE
       AND rl.attribution_confidence = 'CONFIRMED'
       AND rl.created_at >= p_from
       AND rl.created_at < p_to + interval '1 day';
  END IF;

  SELECT coalesce(
    jsonb_agg(
      jsonb_build_object('currency', x.currency, 'amount', x.amount)
      ORDER BY x.currency
    ),
    '[]'::jsonb
  )
    INTO v_revenue_by_currency
    FROM (
      SELECT upper(btrim(rl.currency::text)) AS currency, sum(rl.amount) AS amount
        FROM henvalt.revenue_ledger rl
       WHERE rl.tenant_id = v_tenant.id
         AND rl.entry_type = 'RECOVERY'
         AND rl.billable IS TRUE
         AND rl.attribution_confidence = 'CONFIRMED'
         AND rl.created_at >= p_from
         AND rl.created_at < p_to + interval '1 day'
       GROUP BY upper(btrim(rl.currency::text))
    ) x;

  SELECT coalesce(jsonb_agg(x.item ORDER BY x.created_at DESC), '[]'::jsonb)
    INTO v_activity
    FROM (
      SELECT jsonb_build_object(
        'id', o.id,
        'at', o.created_at,
        'eventType', CASE o.opportunity_type
          WHEN 'ABANDONED_CHECKOUT' THEN 'abandoned_checkout'
          WHEN 'ABANDONED_CART' THEN 'abandoned_cart'
          WHEN 'BROWSE_ABANDONMENT' THEN 'browse_abandonment'
          ELSE 'payment_failure'
        END,
        'summary', CASE
          WHEN EXISTS (
            SELECT 1
              FROM henvalt.order_attributions oa
             WHERE oa.tenant_id = o.tenant_id
               AND oa.opportunity_id = o.id
               AND oa.attribution_confidence = 'CONFIRMED'
               AND oa.evaluated_at >= p_from
               AND oa.evaluated_at < p_to + interval '1 day'
          ) THEN 'Recovered'
          WHEN o.status = 'RECOVERED' THEN 'Closed — attribution unconfirmed'
          WHEN ri.status IN ('SENT', 'DELIVERED') THEN 'Message sent'
          ELSE lower(replace(o.status::text, '_', ' '))
        END,
        'outcome', CASE
          WHEN EXISTS (
            SELECT 1
              FROM henvalt.order_attributions oa
             WHERE oa.tenant_id = o.tenant_id
               AND oa.opportunity_id = o.id
               AND oa.attribution_confidence = 'CONFIRMED'
               AND oa.evaluated_at >= p_from
               AND oa.evaluated_at < p_to + interval '1 day'
          ) THEN 'recovered'
          WHEN o.status = 'RECOVERED' THEN 'unverified'
          WHEN ri.status IN ('SENT', 'DELIVERED') THEN 'sent'
          WHEN ri.status IN ('SKIPPED', 'CANCELLED')
            OR o.status IN ('INELIGIBLE', 'SUPPRESSED') THEN 'skipped'
          ELSE 'pending'
        END,
        'amount', CASE WHEN EXISTS (
          SELECT 1
            FROM henvalt.order_attributions oa
           WHERE oa.tenant_id = o.tenant_id
             AND oa.opportunity_id = o.id
             AND oa.attribution_confidence = 'CONFIRMED'
             AND oa.evaluated_at >= p_from
             AND oa.evaluated_at < p_to + interval '1 day'
        ) THEN NULL ELSE NULL END
      ) AS item,
      o.created_at
      FROM henvalt.opportunities o
      LEFT JOIN LATERAL (
        SELECT ri.status
          FROM henvalt.recovery_interventions ri
         WHERE ri.tenant_id = o.tenant_id
           AND ri.opportunity_id = o.id
         ORDER BY ri.created_at DESC
         LIMIT 1
      ) ri ON true
     WHERE o.tenant_id = v_tenant.id
       AND o.created_at >= p_from
       AND o.created_at < p_to + interval '1 day'
     ORDER BY o.created_at DESC
     LIMIT 8
    ) x;

  SELECT coalesce(jsonb_agg(jsonb_build_object(
    'eventType', e.event_type,
    'opportunities', e.opportunities,
    'interventions', e.interventions,
    'messagesSent', e.messages_sent,
    'recovered', e.recovered,
    'revenueRecovered', e.revenue_recovered
  ) ORDER BY e.event_type), '[]'::jsonb)
    INTO v_by_event
    FROM (
      SELECT m.event_type,
        (SELECT count(*)
           FROM henvalt.opportunities o
          WHERE o.tenant_id = v_tenant.id
            AND o.opportunity_type::text = ANY(m.db_types)
            AND o.created_at >= p_from
            AND o.created_at < p_to + interval '1 day') AS opportunities,
        (SELECT count(*)
           FROM henvalt.recovery_interventions ri
           JOIN henvalt.opportunities o
             ON o.id = ri.opportunity_id AND o.tenant_id = ri.tenant_id
          WHERE ri.tenant_id = v_tenant.id
            AND o.opportunity_type::text = ANY(m.db_types)
            AND ri.created_at >= p_from
            AND ri.created_at < p_to + interval '1 day') AS interventions,
        (SELECT count(*)
           FROM henvalt.recovery_interventions ri
           JOIN henvalt.opportunities o
             ON o.id = ri.opportunity_id AND o.tenant_id = ri.tenant_id
          WHERE ri.tenant_id = v_tenant.id
            AND o.opportunity_type::text = ANY(m.db_types)
            AND ri.status IN ('SENT', 'DELIVERED')
            AND coalesce(ri.sent_at, ri.delivered_at, ri.updated_at) >= p_from
            AND coalesce(ri.sent_at, ri.delivered_at, ri.updated_at) < p_to + interval '1 day') AS messages_sent,
        (SELECT count(DISTINCT oa.order_id)
           FROM henvalt.order_attributions oa
           LEFT JOIN henvalt.opportunities o
             ON o.id = oa.opportunity_id AND o.tenant_id = oa.tenant_id
          WHERE oa.tenant_id = v_tenant.id
            AND oa.attribution_confidence = 'CONFIRMED'
            AND oa.evaluated_at >= p_from
            AND oa.evaluated_at < p_to + interval '1 day'
            AND (
              (m.event_type = 'unclassified' AND o.id IS NULL)
              OR (m.event_type <> 'unclassified' AND o.opportunity_type::text = ANY(m.db_types))
            )) AS recovered,
        CASE WHEN v_currency_conflict THEN NULL ELSE (
          SELECT coalesce(sum(rl.amount), 0)
            FROM henvalt.revenue_ledger rl
            LEFT JOIN henvalt.opportunities o
              ON o.id = rl.opportunity_id AND o.tenant_id = rl.tenant_id
           WHERE rl.tenant_id = v_tenant.id
             AND rl.entry_type = 'RECOVERY'
             AND rl.billable IS TRUE
             AND rl.attribution_confidence = 'CONFIRMED'
             AND rl.created_at >= p_from
             AND rl.created_at < p_to + interval '1 day'
             AND (
               (m.event_type = 'unclassified' AND o.id IS NULL)
               OR (m.event_type <> 'unclassified' AND o.opportunity_type::text = ANY(m.db_types))
             )
        ) END AS revenue_recovered
      FROM (VALUES
        ('abandoned_checkout', ARRAY['ABANDONED_CHECKOUT']::text[]),
        ('abandoned_cart', ARRAY['ABANDONED_CART']::text[]),
        ('browse_abandonment', ARRAY['BROWSE_ABANDONMENT']::text[]),
        ('payment_failure', ARRAY['PAYMENT_FAILURE', 'PAYMENT_DECLINED']::text[]),
        ('unclassified', ARRAY[]::text[])
      ) m(event_type, db_types)
    ) e;

  RETURN jsonb_build_object(
    'linked', true,
    'shopName', v_conn.shop_domain,
    'currency', v_currency,
    'revenueCurrencyConflict', v_currency_conflict,
    'revenueByCurrency', v_revenue_by_currency,
    'metrics', jsonb_build_object(
      'revenueRecovered', v_revenue,
      'currency', v_currency,
      'opportunities', v_opportunities,
      'recoveryRate', CASE WHEN v_opportunities > 0
        THEN round((v_recovered::numeric / v_opportunities::numeric) * 100, 2)
        ELSE NULL END,
      'messagesSent', v_messages,
      'recoveredOrders', v_recovered
    ),
    'activity', v_activity,
    'totals', jsonb_build_object(
      'opportunities', v_opportunities,
      'interventions', (
        SELECT count(*)
          FROM henvalt.recovery_interventions ri
         WHERE ri.tenant_id = v_tenant.id
           AND ri.created_at >= p_from
           AND ri.created_at < p_to + interval '1 day'
      ),
      'messagesSent', v_messages,
      'recovered', v_recovered,
      'revenueRecovered', v_revenue
    ),
    'byEvent', v_by_event
  );
END;
$function$;

CREATE OR REPLACE FUNCTION henvalt.control_plane_revenue_series(
  p_shop_domain text,
  p_from timestamptz,
  p_to timestamptz,
  p_granularity text DEFAULT 'day'
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO pg_catalog, henvalt, public, pg_temp
AS $function$
DECLARE
  v_shop text := lower(btrim(p_shop_domain));
  v_tenant_id uuid;
  v_default_currency text;
  v_current_currency text;
  v_previous_currency text;
  v_current_currency_count integer := 0;
  v_previous_currency_count integer := 0;
  v_current_currency_conflict boolean := false;
  v_comparison_currency_conflict boolean := false;
  v_currencies jsonb := '[]'::jsonb;
  v_days integer;
  v_previous_from timestamptz;
  v_previous_revenue numeric;
  v_current_revenue numeric;
  v_change_percent numeric;
  v_step interval;
  v_series jsonb := '[]'::jsonb;
BEGIN
  IF p_from IS NULL OR p_to IS NULL OR p_to < p_from
     OR p_to - p_from > interval '366 days'
     OR p_granularity NOT IN ('day', 'week', 'month') THEN
    RAISE EXCEPTION 'invalid_revenue_series_request';
  END IF;

  SELECT sc.tenant_id, coalesce(nullif(btrim(t.default_currency::text), ''), 'USD')
    INTO v_tenant_id, v_default_currency
    FROM henvalt.shopify_connections sc
    JOIN henvalt.tenants t ON t.id = sc.tenant_id
   WHERE sc.shop_domain = v_shop
     AND sc.active IS TRUE
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

  SELECT count(DISTINCT upper(btrim(rl.currency::text)))::integer,
         max(upper(btrim(rl.currency::text)))
    INTO v_current_currency_count, v_current_currency
    FROM henvalt.revenue_ledger rl
   WHERE rl.tenant_id = v_tenant_id
     AND rl.entry_type = 'RECOVERY'
     AND rl.billable IS TRUE
     AND rl.attribution_confidence = 'CONFIRMED'
     AND rl.created_at >= p_from
     AND rl.created_at < p_to + interval '1 day';

  SELECT count(DISTINCT upper(btrim(rl.currency::text)))::integer,
         max(upper(btrim(rl.currency::text)))
    INTO v_previous_currency_count, v_previous_currency
    FROM henvalt.revenue_ledger rl
   WHERE rl.tenant_id = v_tenant_id
     AND rl.entry_type = 'RECOVERY'
     AND rl.billable IS TRUE
     AND rl.attribution_confidence = 'CONFIRMED'
     AND rl.created_at >= v_previous_from
     AND rl.created_at < p_from;

  v_current_currency_conflict := v_current_currency_count > 1;
  v_current_currency := CASE
    WHEN v_current_currency_count = 1 THEN v_current_currency
    ELSE v_default_currency
  END;
  v_comparison_currency_conflict :=
    v_current_currency_conflict
    OR v_previous_currency_count > 1
    OR (v_previous_currency_count = 1 AND v_previous_currency <> v_current_currency);

  SELECT coalesce(
    jsonb_agg(DISTINCT upper(btrim(rl.currency::text)) ORDER BY upper(btrim(rl.currency::text))),
    '[]'::jsonb
  )
    INTO v_currencies
    FROM henvalt.revenue_ledger rl
   WHERE rl.tenant_id = v_tenant_id
     AND rl.entry_type = 'RECOVERY'
     AND rl.billable IS TRUE
     AND rl.attribution_confidence = 'CONFIRMED'
     AND rl.created_at >= v_previous_from
     AND rl.created_at < p_to + interval '1 day';

  IF v_current_currency_conflict THEN
    v_current_revenue := NULL;
    v_series := '[]'::jsonb;
  ELSE
    SELECT coalesce(sum(rl.amount), 0)
      INTO v_current_revenue
      FROM henvalt.revenue_ledger rl
     WHERE rl.tenant_id = v_tenant_id
       AND rl.entry_type = 'RECOVERY'
       AND rl.billable IS TRUE
       AND rl.attribution_confidence = 'CONFIRMED'
       AND rl.currency::text = v_current_currency
       AND rl.created_at >= p_from
       AND rl.created_at < p_to + interval '1 day';

    WITH buckets AS (
      SELECT generate_series(
        date_trunc(p_granularity, p_from),
        date_trunc(p_granularity, p_to),
        v_step
      ) AS bucket
    ),
    totals AS (
      SELECT date_trunc(p_granularity, rl.created_at) AS bucket,
             sum(rl.amount) AS revenue
        FROM henvalt.revenue_ledger rl
       WHERE rl.tenant_id = v_tenant_id
         AND rl.entry_type = 'RECOVERY'
         AND rl.billable IS TRUE
         AND rl.attribution_confidence = 'CONFIRMED'
         AND rl.currency::text = v_current_currency
         AND rl.created_at >= p_from
         AND rl.created_at < p_to + interval '1 day'
       GROUP BY 1
    )
    SELECT coalesce(
      jsonb_agg(
        jsonb_build_object(
          'bucket', b.bucket,
          'recovered_revenue', coalesce(t.revenue, 0)
        )
        ORDER BY b.bucket
      ),
      '[]'::jsonb
    )
      INTO v_series
      FROM buckets b
      LEFT JOIN totals t USING (bucket);
  END IF;

  IF v_comparison_currency_conflict THEN
    v_previous_revenue := NULL;
  ELSE
    SELECT coalesce(sum(rl.amount), 0)
      INTO v_previous_revenue
      FROM henvalt.revenue_ledger rl
     WHERE rl.tenant_id = v_tenant_id
       AND rl.entry_type = 'RECOVERY'
       AND rl.billable IS TRUE
       AND rl.attribution_confidence = 'CONFIRMED'
       AND rl.currency::text = v_current_currency
       AND rl.created_at >= v_previous_from
       AND rl.created_at < p_from;
  END IF;

  v_change_percent := CASE
    WHEN v_comparison_currency_conflict OR v_previous_revenue IS NULL OR v_previous_revenue = 0
      THEN NULL
    ELSE round(((v_current_revenue - v_previous_revenue) / abs(v_previous_revenue)) * 100, 2)
  END;

  RETURN jsonb_build_object(
    'series', v_series,
    'currency', v_current_currency,
    'currencies', v_currencies,
    'current_currency_conflict', v_current_currency_conflict,
    'comparison_currency_conflict', v_comparison_currency_conflict,
    'current_revenue', v_current_revenue,
    'previous_revenue', v_previous_revenue,
    'change_percent', v_change_percent,
    'previous_from', v_previous_from,
    'previous_to', p_from - interval '1 day'
  );
END;
$function$;

REVOKE ALL ON FUNCTION henvalt.control_plane_dashboard_summary(text, timestamptz, timestamptz)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION henvalt.control_plane_dashboard_summary(text, timestamptz, timestamptz)
  TO service_role;

REVOKE ALL ON FUNCTION henvalt.control_plane_revenue_series(text, timestamptz, timestamptz, text)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION henvalt.control_plane_revenue_series(text, timestamptz, timestamptz, text)
  TO service_role;

COMMIT;

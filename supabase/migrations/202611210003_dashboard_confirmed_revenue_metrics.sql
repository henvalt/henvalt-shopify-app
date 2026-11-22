-- Dashboard recovered-order activity must come from confirmed order attribution,
-- while revenue totals remain sourced from confirmed billable revenue-ledger entries.
-- Candidate migration only; validate in isolated staging before any deployment.
BEGIN;

CREATE OR REPLACE FUNCTION henvalt.control_plane_dashboard_summary(p_shop_domain text, p_from timestamp with time zone, p_to timestamp with time zone)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO pg_catalog, henvalt, pg_temp
AS $function$
DECLARE
  v_shop text := lower(trim(p_shop_domain));
  v_conn henvalt.shopify_connections%rowtype;
  v_tenant henvalt.tenants%rowtype;
  v_opportunities bigint;
  v_messages bigint;
  v_recovered bigint;
  v_revenue numeric;
  v_currency text;
  v_activity jsonb;
  v_by_event jsonb;
BEGIN
  SELECT * INTO v_conn
  FROM henvalt.shopify_connections
  WHERE shop_domain = v_shop AND active = true
  LIMIT 1;
  IF NOT FOUND THEN RETURN jsonb_build_object('linked', false); END IF;

  SELECT * INTO v_tenant
  FROM henvalt.tenants
  WHERE id = v_conn.tenant_id AND status = 'ACTIVE';
  IF NOT FOUND THEN RETURN jsonb_build_object('linked', false); END IF;

  IF p_from IS NULL OR p_to IS NULL OR p_to < p_from OR p_to - p_from > interval '366 days' THEN
    RAISE EXCEPTION 'invalid_date_range';
  END IF;

  SELECT count(*) INTO v_opportunities
  FROM henvalt.opportunities o
  WHERE o.tenant_id = v_tenant.id
    AND o.created_at >= p_from AND o.created_at < p_to + interval '1 day';

  SELECT count(*) INTO v_messages
  FROM henvalt.recovery_interventions ri
  WHERE ri.tenant_id = v_tenant.id
    AND ri.status IN ('SENT', 'DELIVERED')
    AND COALESCE(ri.sent_at, ri.delivered_at, ri.updated_at) >= p_from
    AND COALESCE(ri.sent_at, ri.delivered_at, ri.updated_at) < p_to + interval '1 day';

  SELECT count(DISTINCT oa.order_id) INTO v_recovered
  FROM henvalt.order_attributions oa
  WHERE oa.tenant_id = v_tenant.id
    AND oa.evaluated_at >= p_from AND oa.evaluated_at < p_to + interval '1 day'
    AND oa.attribution_confidence = 'CONFIRMED';

  SELECT coalesce(sum(rl.amount), 0) INTO v_revenue
  FROM henvalt.revenue_ledger rl
  WHERE rl.tenant_id = v_tenant.id
    AND rl.entry_type IN ('RECOVERY', 'ADJUSTMENT') AND rl.billable IS TRUE AND rl.attribution_confidence = 'CONFIRMED'
    AND rl.created_at >= p_from AND rl.created_at < p_to + interval '1 day';

  SELECT COALESCE(
    (SELECT NULLIF(btrim(o.currency::text), '')
       FROM henvalt.opportunities o
      WHERE o.tenant_id = v_tenant.id
      ORDER BY o.updated_at DESC
      LIMIT 1),
    (SELECT NULLIF(btrim(rl.currency::text), '')
       FROM henvalt.revenue_ledger rl
      WHERE rl.tenant_id = v_tenant.id
        AND rl.entry_type IN ('RECOVERY', 'ADJUSTMENT') AND rl.billable IS TRUE AND rl.attribution_confidence = 'CONFIRMED'
      ORDER BY rl.created_at DESC
      LIMIT 1),
    NULLIF(btrim(v_tenant.default_currency::text), ''),
    'USD'
  ) INTO v_currency;

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
        WHEN ri.has_confirmed_attribution IS TRUE THEN 'Recovered'
        WHEN o.status = 'RECOVERED' THEN 'Awaiting confirmed attribution'
        WHEN ri.status IN ('SENT', 'DELIVERED') THEN 'Message sent'
        ELSE lower(replace(o.status::text, '_', ' '))
      END,
      'outcome', CASE
        WHEN ri.has_confirmed_attribution IS TRUE THEN 'recovered'
        WHEN o.status = 'RECOVERED' THEN 'pending'
        WHEN ri.status IN ('SENT', 'DELIVERED') THEN 'sent'
        WHEN ri.status IN ('SKIPPED', 'CANCELLED')
          OR o.status IN ('INELIGIBLE', 'SUPPRESSED') THEN 'skipped'
        ELSE 'pending'
      END,
      'amount', CASE WHEN ri.has_confirmed_attribution IS TRUE THEN ri.attributed_value ELSE NULL END
    ) AS item,
    o.created_at
    FROM henvalt.opportunities o
    LEFT JOIN LATERAL (
      SELECT ri.status,
        EXISTS (
          SELECT 1
          FROM henvalt.order_attributions oa
          WHERE oa.tenant_id = o.tenant_id
            AND oa.opportunity_id = o.id
            AND oa.attribution_confidence = 'CONFIRMED'
        ) AS has_confirmed_attribution,
        (SELECT oa.attributed_value + COALESCE((
             SELECT sum(rl.amount)
               FROM henvalt.revenue_ledger rl
              WHERE rl.tenant_id = oa.tenant_id
                AND rl.order_id = oa.order_id
                AND rl.entry_type = 'ADJUSTMENT'
                AND rl.billable IS TRUE
                AND rl.attribution_confidence = 'CONFIRMED'
           ), 0)
           FROM henvalt.order_attributions oa
          WHERE oa.tenant_id = o.tenant_id
            AND oa.opportunity_id = o.id
            AND oa.attribution_confidence = 'CONFIRMED'
          ORDER BY oa.evaluated_at DESC
          LIMIT 1) AS attributed_value
      FROM henvalt.recovery_interventions ri
      WHERE ri.tenant_id = o.tenant_id AND ri.opportunity_id = o.id
      ORDER BY ri.created_at DESC
      LIMIT 1
    ) ri ON true
    WHERE o.tenant_id = v_tenant.id
      AND o.created_at >= p_from AND o.created_at < p_to + interval '1 day'
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
  )), '[]'::jsonb)
  INTO v_by_event
  FROM (
    SELECT m.event_type,
      (SELECT count(*)
         FROM henvalt.opportunities o
        WHERE o.tenant_id = v_tenant.id
          AND o.opportunity_type::text = any(m.db_types)
          AND o.created_at >= p_from AND o.created_at < p_to + interval '1 day') AS opportunities,
      (SELECT count(*)
         FROM henvalt.recovery_interventions ri
         JOIN henvalt.opportunities o
           ON o.id = ri.opportunity_id AND o.tenant_id = ri.tenant_id
        WHERE ri.tenant_id = v_tenant.id
          AND o.opportunity_type::text = any(m.db_types)
          AND ri.created_at >= p_from AND ri.created_at < p_to + interval '1 day') AS interventions,
      (SELECT count(*)
         FROM henvalt.recovery_interventions ri
         JOIN henvalt.opportunities o
           ON o.id = ri.opportunity_id AND o.tenant_id = ri.tenant_id
        WHERE ri.tenant_id = v_tenant.id
          AND o.opportunity_type::text = any(m.db_types)
          AND ri.status IN ('SENT', 'DELIVERED')
          AND COALESCE(ri.sent_at, ri.delivered_at, ri.updated_at) >= p_from
          AND COALESCE(ri.sent_at, ri.delivered_at, ri.updated_at) < p_to + interval '1 day') AS messages_sent,
      (SELECT count(DISTINCT oa.order_id)
         FROM henvalt.order_attributions oa
         JOIN henvalt.opportunities o
           ON o.id = oa.opportunity_id AND o.tenant_id = oa.tenant_id
        WHERE oa.tenant_id = v_tenant.id
          AND o.opportunity_type::text = any(m.db_types)
          AND oa.attribution_confidence = 'CONFIRMED'
          AND oa.evaluated_at >= p_from AND oa.evaluated_at < p_to + interval '1 day') AS recovered,
      (SELECT coalesce(sum(rl.amount), 0)
         FROM henvalt.revenue_ledger rl
         JOIN henvalt.opportunities o
           ON o.id = rl.opportunity_id AND o.tenant_id = rl.tenant_id
        WHERE rl.tenant_id = v_tenant.id
          AND o.opportunity_type::text = any(m.db_types)
          AND rl.entry_type IN ('RECOVERY', 'ADJUSTMENT') AND rl.billable IS TRUE AND rl.attribution_confidence = 'CONFIRMED'
          AND rl.created_at >= p_from AND rl.created_at < p_to + interval '1 day') AS revenue_recovered
    FROM (VALUES
      ('abandoned_checkout', ARRAY['ABANDONED_CHECKOUT']::text[]),
      ('abandoned_cart', ARRAY['ABANDONED_CART']::text[]),
      ('browse_abandonment', ARRAY['BROWSE_ABANDONMENT']::text[]),
      ('payment_failure', ARRAY['PAYMENT_FAILURE', 'PAYMENT_DECLINED']::text[])
    ) m(event_type, db_types)
  ) e;

  RETURN jsonb_build_object(
    'linked', true,
    'shopName', v_conn.shop_domain,
    'currency', v_currency,
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
      'interventions', (SELECT count(*)
        FROM henvalt.recovery_interventions ri
        WHERE ri.tenant_id = v_tenant.id
          AND ri.created_at >= p_from AND ri.created_at < p_to + interval '1 day'),
      'messagesSent', v_messages,
      'recovered', v_recovered,
      'revenueRecovered', v_revenue
    ),
    'byEvent', v_by_event
  );
END;
$function$;

COMMIT;

-- HENVALT exact-store V2 merchant dashboard read model.
-- PREPARATION ONLY. Replaces legacy tenant-wide dashboard aggregates with
-- exact-connection opportunity, send-attempt and confirmed-attribution data.
BEGIN;

CREATE OR REPLACE FUNCTION henvalt.control_plane_dashboard_summary_v2(
  p_shopify_connection_id uuid,
  p_from timestamptz,
  p_to timestamptz
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_shop text;
  v_tenant_id uuid;
  v_currency text;
  v_currency_count integer:=0;
  v_currency_mixed boolean:=false;
  v_opportunities bigint:=0;
  v_messages bigint:=0;
  v_recovered bigint:=0;
  v_interventions bigint:=0;
  v_revenue numeric(18,4):=0;
  v_activity jsonb:='[]'::jsonb;
  v_by_event jsonb:='[]'::jsonb;
  v_revenue_series jsonb:='[]'::jsonb;
BEGIN
  SELECT sc.shop_domain,sc.tenant_id
    INTO v_shop,v_tenant_id
  FROM henvalt.shopify_connections sc
  JOIN henvalt.tenants t ON t.id=sc.tenant_id AND t.status='ACTIVE'
  JOIN henvalt.shopify_app_registry ar ON ar.app_key=sc.app_key AND ar.lifecycle_status='active'
  WHERE sc.id=p_shopify_connection_id AND sc.active IS TRUE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('linked',false);
  END IF;

  IF p_from IS NULL OR p_to IS NULL OR p_to<p_from
     OR p_to-p_from>interval '366 days' THEN
    RAISE EXCEPTION 'invalid_date_range';
  END IF;

  SELECT count(DISTINCT a.currency),max(a.currency),count(DISTINCT a.order_identity_id),
         COALESCE(sum(a.net_recovered_amount),0)
    INTO v_currency_count,v_currency,v_recovered,v_revenue
  FROM henvalt.shopify_recovery_attributions_v2 a
  WHERE a.tenant_id=v_tenant_id
    AND a.shopify_connection_id=p_shopify_connection_id
    AND a.status='CONFIRMED'
    AND a.net_recovered_amount>0
    AND a.attributed_at>=p_from
    AND a.attributed_at<p_to+interval '1 day';
  v_currency_mixed:=v_currency_count>1;
  IF v_currency_mixed THEN
    v_currency:=COALESCE(
      (SELECT upper(o.currency) FROM henvalt.shopify_order_identity_v2 o
       WHERE o.tenant_id=v_tenant_id AND o.shopify_connection_id=p_shopify_connection_id
         AND o.currency IS NOT NULL ORDER BY o.ordered_at DESC NULLS LAST LIMIT 1),
      (SELECT upper(o.currency) FROM henvalt.shopify_recovery_opportunity_v2 o
       WHERE o.tenant_id=v_tenant_id AND o.shopify_connection_id=p_shopify_connection_id
         AND o.currency IS NOT NULL ORDER BY o.updated_at DESC LIMIT 1),
      'USD'
    );
    v_revenue:=NULL;
  ELSIF v_currency_count=0 THEN
    SELECT COALESCE(
      (SELECT upper(o.currency) FROM henvalt.shopify_order_identity_v2 o
       WHERE o.tenant_id=v_tenant_id AND o.shopify_connection_id=p_shopify_connection_id
         AND o.currency IS NOT NULL ORDER BY o.ordered_at DESC NULLS LAST LIMIT 1),
      (SELECT upper(o.currency) FROM henvalt.shopify_recovery_opportunity_v2 o
       WHERE o.tenant_id=v_tenant_id AND o.shopify_connection_id=p_shopify_connection_id
         AND o.currency IS NOT NULL ORDER BY o.updated_at DESC LIMIT 1),
      'USD'
    ) INTO v_currency;
    v_revenue:=0;
  END IF;

  SELECT count(*) INTO v_opportunities
  FROM henvalt.shopify_recovery_opportunity_v2 o
  WHERE o.tenant_id=v_tenant_id
    AND o.shopify_connection_id=p_shopify_connection_id
    AND o.created_at>=p_from
    AND o.created_at<p_to+interval '1 day';

  SELECT
    (SELECT count(DISTINCT a.id)
     FROM henvalt.shopify_recovery_send_attempt_v2 a
     JOIN henvalt.shopify_recovery_intervention_v2 i
       ON i.id=a.intervention_id AND i.tenant_id=a.tenant_id
      AND i.shopify_connection_id=a.shopify_connection_id
     WHERE a.tenant_id=v_tenant_id
       AND a.shopify_connection_id=p_shopify_connection_id
       AND a.status IN ('SUBMITTED','DELIVERED','SOFT_BOUNCED','HARD_BOUNCED','UNSUBSCRIBED','COMPLAINED')
       AND a.submitted_at>=p_from AND a.submitted_at<p_to+interval '1 day')
    +
    (SELECT count(DISTINCT a.id)
     FROM henvalt.shopify_pixel_send_attempts_v2 a
     JOIN henvalt.shopify_mailer_provider_events_v2 e
       ON e.pixel_send_attempt_id=a.id AND e.tenant_id=a.tenant_id
      AND e.shopify_connection_id=a.shopify_connection_id
     WHERE a.tenant_id=v_tenant_id
       AND a.shopify_connection_id=p_shopify_connection_id
       AND a.status='SUBMITTED'
       AND e.processing_status='PROCESSED'
       AND e.event_type IN ('activity.sent','activity.delivered')
       AND e.occurred_at>=p_from AND e.occurred_at<p_to+interval '1 day')
    INTO v_messages;

  SELECT count(*) INTO v_interventions
  FROM henvalt.shopify_recovery_intervention_v2 i
  WHERE i.tenant_id=v_tenant_id
    AND i.shopify_connection_id=p_shopify_connection_id
    AND i.created_at>=p_from AND i.created_at<p_to+interval '1 day';

  SELECT COALESCE(jsonb_agg(x.item ORDER BY x.created_at DESC),'[]'::jsonb)
    INTO v_activity
  FROM (
    SELECT
      jsonb_build_object(
        'id',o.id,
        'at',o.created_at,
        'eventType',CASE o.opportunity_type
          WHEN 'ABANDONED_CHECKOUT' THEN 'abandoned_checkout'
          WHEN 'ABANDONED_CART' THEN 'abandoned_cart'
          WHEN 'BROWSE_ABANDONMENT' THEN 'browse_abandonment'
          ELSE 'recovery_opportunity' END,
        'summary',CASE
          WHEN a.status='CONFIRMED' THEN 'Recovered order'
          WHEN COALESCE(pixel_attempt.status,checkout_attempt.status) IN
            ('SUBMITTED','DELIVERED','SOFT_BOUNCED','HARD_BOUNCED','UNSUBSCRIBED','COMPLAINED')
            THEN 'Message sent'
          WHEN COALESCE(pixel_attempt.status,checkout_attempt.status)='FAILED' THEN 'Delivery failed'
          WHEN o.status='CLOSED' THEN 'Opportunity closed'
          ELSE 'Awaiting recovery' END,
        'outcome',CASE
          WHEN a.status='CONFIRMED' THEN 'recovered'
          WHEN COALESCE(pixel_attempt.status,checkout_attempt.status) IN
            ('SUBMITTED','DELIVERED','SOFT_BOUNCED','HARD_BOUNCED','UNSUBSCRIBED','COMPLAINED')
            THEN 'sent'
          WHEN COALESCE(pixel_attempt.status,checkout_attempt.status) IN ('FAILED','CANCELLED')
            OR o.status='CLOSED' THEN 'skipped'
          ELSE 'pending' END,
        'amount',CASE WHEN a.status='CONFIRMED' THEN a.net_recovered_amount ELSE NULL END,
        'currency',CASE WHEN a.status='CONFIRMED' THEN a.currency ELSE NULL END
      ) AS item,
      o.created_at
    FROM henvalt.shopify_recovery_opportunity_v2 o
    LEFT JOIN henvalt.shopify_recovery_attributions_v2 a
      ON a.opportunity_id=o.id AND a.tenant_id=o.tenant_id
     AND a.shopify_connection_id=o.shopify_connection_id
    LEFT JOIN LATERAL (
      SELECT sa.status
      FROM henvalt.shopify_recovery_intervention_v2 i
      JOIN henvalt.shopify_recovery_send_attempt_v2 sa
        ON sa.intervention_id=i.id AND sa.tenant_id=i.tenant_id
       AND sa.shopify_connection_id=i.shopify_connection_id
      WHERE i.opportunity_id=o.id AND i.tenant_id=o.tenant_id
        AND i.shopify_connection_id=o.shopify_connection_id
      ORDER BY sa.created_at DESC LIMIT 1
    ) checkout_attempt ON true
    LEFT JOIN LATERAL (
      SELECT pa.status
      FROM henvalt.shopify_pixel_send_attempts_v2 pa
      WHERE pa.opportunity_id=o.id AND pa.tenant_id=o.tenant_id
        AND pa.shopify_connection_id=o.shopify_connection_id
      ORDER BY pa.created_at DESC LIMIT 1
    ) pixel_attempt ON true
    WHERE o.tenant_id=v_tenant_id
      AND o.shopify_connection_id=p_shopify_connection_id
      AND o.created_at>=p_from
      AND o.created_at<p_to+interval '1 day'
    ORDER BY o.created_at DESC
    LIMIT 8
  ) x;

  SELECT COALESCE(jsonb_agg(
    jsonb_build_object(
      'eventType',m.event_type,
      'opportunities',stats.opportunities,
      'interventions',stats.interventions,
      'messagesSent',stats.messages_sent,
      'recovered',stats.recovered,
      'revenueRecovered',CASE WHEN stats.currency_count<=1 THEN stats.revenue ELSE NULL END,
      'currencyMixed',stats.currency_count>1,
      'currency',CASE WHEN stats.currency_count=1 THEN stats.currency ELSE v_currency END
    ) ORDER BY m.sort_order
  ),'[]'::jsonb) INTO v_by_event
  FROM (VALUES
    (1,'abandoned_checkout','ABANDONED_CHECKOUT'),
    (2,'abandoned_cart','ABANDONED_CART'),
    (3,'browse_abandonment','BROWSE_ABANDONMENT')
  ) m(sort_order,event_type,db_type)
  CROSS JOIN LATERAL (
    SELECT
      (SELECT count(*) FROM henvalt.shopify_recovery_opportunity_v2 o
       WHERE o.tenant_id=v_tenant_id AND o.shopify_connection_id=p_shopify_connection_id
         AND o.opportunity_type=m.db_type
         AND o.created_at>=p_from AND o.created_at<p_to+interval '1 day') AS opportunities,
      (SELECT count(*) FROM henvalt.shopify_recovery_intervention_v2 i
       JOIN henvalt.shopify_recovery_opportunity_v2 o
         ON o.id=i.opportunity_id AND o.tenant_id=i.tenant_id
        AND o.shopify_connection_id=i.shopify_connection_id
       WHERE i.tenant_id=v_tenant_id AND i.shopify_connection_id=p_shopify_connection_id
         AND o.opportunity_type=m.db_type
         AND i.created_at>=p_from AND i.created_at<p_to+interval '1 day') AS interventions,
      (SELECT count(DISTINCT sent_attempt.id)
       FROM (
         SELECT sa.id
         FROM henvalt.shopify_recovery_send_attempt_v2 sa
         JOIN henvalt.shopify_recovery_intervention_v2 i
           ON i.id=sa.intervention_id AND i.tenant_id=sa.tenant_id
          AND i.shopify_connection_id=sa.shopify_connection_id
         JOIN henvalt.shopify_recovery_opportunity_v2 o
           ON o.id=i.opportunity_id AND o.tenant_id=i.tenant_id
          AND o.shopify_connection_id=i.shopify_connection_id
         WHERE sa.tenant_id=v_tenant_id AND sa.shopify_connection_id=p_shopify_connection_id
           AND o.opportunity_type=m.db_type
           AND sa.status IN ('SUBMITTED','DELIVERED','SOFT_BOUNCED','HARD_BOUNCED','UNSUBSCRIBED','COMPLAINED')
           AND sa.submitted_at>=p_from AND sa.submitted_at<p_to+interval '1 day'
         UNION
         SELECT pa.id
         FROM henvalt.shopify_pixel_send_attempts_v2 pa
         JOIN henvalt.shopify_recovery_opportunity_v2 o
           ON o.id=pa.opportunity_id AND o.tenant_id=pa.tenant_id
          AND o.shopify_connection_id=pa.shopify_connection_id
         JOIN henvalt.shopify_mailer_provider_events_v2 e
           ON e.pixel_send_attempt_id=pa.id AND e.tenant_id=pa.tenant_id
          AND e.shopify_connection_id=pa.shopify_connection_id
         WHERE pa.tenant_id=v_tenant_id AND pa.shopify_connection_id=p_shopify_connection_id
           AND o.opportunity_type=m.db_type AND pa.status='SUBMITTED'
           AND e.processing_status='PROCESSED'
           AND e.event_type IN ('activity.sent','activity.delivered')
           AND e.occurred_at>=p_from AND e.occurred_at<p_to+interval '1 day'
       ) sent_attempt
      ) AS messages_sent,
      (SELECT count(DISTINCT a.order_identity_id)
       FROM henvalt.shopify_recovery_attributions_v2 a
       JOIN henvalt.shopify_recovery_opportunity_v2 o
         ON o.id=a.opportunity_id AND o.tenant_id=a.tenant_id
        AND o.shopify_connection_id=a.shopify_connection_id
       WHERE a.tenant_id=v_tenant_id AND a.shopify_connection_id=p_shopify_connection_id
         AND o.opportunity_type=m.db_type AND a.status='CONFIRMED'
         AND a.attributed_at>=p_from AND a.attributed_at<p_to+interval '1 day') AS recovered,
      (SELECT count(DISTINCT a.currency)
       FROM henvalt.shopify_recovery_attributions_v2 a
       JOIN henvalt.shopify_recovery_opportunity_v2 o
         ON o.id=a.opportunity_id AND o.tenant_id=a.tenant_id
        AND o.shopify_connection_id=a.shopify_connection_id
       WHERE a.tenant_id=v_tenant_id AND a.shopify_connection_id=p_shopify_connection_id
         AND o.opportunity_type=m.db_type AND a.status='CONFIRMED'
         AND a.attributed_at>=p_from AND a.attributed_at<p_to+interval '1 day') AS currency_count,
      (SELECT max(a.currency)
       FROM henvalt.shopify_recovery_attributions_v2 a
       JOIN henvalt.shopify_recovery_opportunity_v2 o
         ON o.id=a.opportunity_id AND o.tenant_id=a.tenant_id
        AND o.shopify_connection_id=a.shopify_connection_id
       WHERE a.tenant_id=v_tenant_id AND a.shopify_connection_id=p_shopify_connection_id
         AND o.opportunity_type=m.db_type AND a.status='CONFIRMED'
         AND a.attributed_at>=p_from AND a.attributed_at<p_to+interval '1 day') AS currency,
      (SELECT COALESCE(sum(a.net_recovered_amount),0)
       FROM henvalt.shopify_recovery_attributions_v2 a
       JOIN henvalt.shopify_recovery_opportunity_v2 o
         ON o.id=a.opportunity_id AND o.tenant_id=a.tenant_id
        AND o.shopify_connection_id=a.shopify_connection_id
       WHERE a.tenant_id=v_tenant_id AND a.shopify_connection_id=p_shopify_connection_id
         AND o.opportunity_type=m.db_type AND a.status='CONFIRMED'
         AND a.attributed_at>=p_from AND a.attributed_at<p_to+interval '1 day') AS revenue
  ) stats;

  -- Daily confirmed recovery values for the selected exact store only.
  SELECT COALESCE(jsonb_agg(
    jsonb_build_object(
      'date',x.day::date,
      'amount',CASE WHEN x.currency_count<=1 THEN x.amount ELSE NULL END,
      'currencyMixed',x.currency_count>1,
      'currency',CASE WHEN x.currency_count=1 THEN x.currency ELSE v_currency END
    ) ORDER BY x.day
  ),'[]'::jsonb) INTO v_revenue_series
  FROM (
    SELECT d.day,
      count(DISTINCT a.currency) AS currency_count,
      max(a.currency) AS currency,
      COALESCE(sum(a.net_recovered_amount),0) AS amount
    FROM generate_series(
      date_trunc('day',p_from AT TIME ZONE 'UTC'),
      date_trunc('day',p_to AT TIME ZONE 'UTC'),
      interval '1 day'
    ) AS d(day)
    LEFT JOIN henvalt.shopify_recovery_attributions_v2 a
      ON a.tenant_id=v_tenant_id
     AND a.shopify_connection_id=p_shopify_connection_id
     AND a.status='CONFIRMED'
     AND a.net_recovered_amount>0
     AND a.attributed_at >= (d.day AT TIME ZONE 'UTC')
     AND a.attributed_at < ((d.day+interval '1 day') AT TIME ZONE 'UTC')
    GROUP BY d.day
  ) x;

  RETURN jsonb_build_object(
    'linked',true,
    'shopName',v_shop,
    'currency',v_currency,
    'currencyMixed',v_currency_mixed,
    'metrics',jsonb_build_object(
      'revenueRecovered',v_revenue,
      'currency',v_currency,
      'currencyMixed',v_currency_mixed,
      'opportunities',v_opportunities,
      'recoveryRate',CASE WHEN v_opportunities>0
        THEN round((v_recovered::numeric/v_opportunities::numeric)*100,2) ELSE NULL END,
      'messagesSent',v_messages,
      'recoveredOrders',v_recovered
    ),
    'activity',v_activity,
    'revenueSeries',v_revenue_series,
    'totals',jsonb_build_object(
      'opportunities',v_opportunities,
      'interventions',v_interventions,
      'messagesSent',v_messages,
      'recovered',v_recovered,
      'revenueRecovered',v_revenue,
      'currencyMixed',v_currency_mixed
    ),
    'byEvent',v_by_event
  );
END;
$function$;

REVOKE ALL ON FUNCTION henvalt.control_plane_dashboard_summary_v2(uuid,timestamptz,timestamptz)
  FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION henvalt.control_plane_dashboard_summary_v2(uuid,timestamptz,timestamptz)
  TO service_role;

COMMENT ON FUNCTION henvalt.control_plane_dashboard_summary_v2(uuid,timestamptz,timestamptz) IS
  'Exact-connection V2 dashboard summary. Counts recovered revenue only from CONFIRMED recovered-order attribution; never reads legacy tenant-wide ledgers.';
COMMIT;

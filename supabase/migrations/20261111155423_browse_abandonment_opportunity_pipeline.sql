CREATE OR REPLACE FUNCTION henvalt.process_browse_abandonment_candidates(
  p_inactivity_minutes integer DEFAULT 60,
  p_max_age_hours integer DEFAULT 24,
  p_limit integer DEFAULT 100
)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'henvalt', 'public', 'pg_temp'
AS $function$
DECLARE
  r record;
  v_opportunity_id uuid;
  v_recovery_id uuid;
  v_status henvalt.opportunity_status;
  v_created integer := 0;
  v_queued integer := 0;
  v_suppressed integer := 0;
  v_key text;
BEGIN
  FOR r IN SELECT * FROM henvalt.get_browse_abandonment_candidates(
    p_inactivity_minutes,p_max_age_hours,p_limit
  ) LOOP
    v_key := 'browse:'||r.tenant_id::text||':'||md5(r.session_reference||':'||r.product_id);
    INSERT INTO henvalt.opportunities(
      tenant_id,customer_id,checkout_id,source_event_id,opportunity_type,status,
      value_at_risk,currency,confidence_score,idempotency_key,correlation_id,expires_at,metadata
    ) VALUES (
      r.tenant_id,r.customer_id,NULL,r.source_event_id,
      'BROWSE_ABANDONMENT'::henvalt.opportunity_type,'DETECTED',
      r.price_amount,r.currency,0.70,v_key,gen_random_uuid(),now()+interval '24 hours',
      jsonb_build_object(
        'session_reference',r.session_reference,'shop_domain',r.shop_domain,
        'product_id',r.product_id,'product_title',r.product_title,'variant_id',r.variant_id,
        'price_amount',r.price_amount,'currency',r.currency,'destination_url',r.destination_url,
        'last_activity_at',r.last_activity_at,'source_event_id',r.source_event_id,'context_version',1
      )
    ) ON CONFLICT (tenant_id,idempotency_key) DO NOTHING
    RETURNING id INTO v_opportunity_id;

    IF v_opportunity_id IS NULL THEN
      SELECT id INTO v_opportunity_id FROM henvalt.opportunities
      WHERE tenant_id=r.tenant_id AND idempotency_key=v_key;
    ELSE
      v_created := v_created+1;
    END IF;
    IF v_opportunity_id IS NULL THEN CONTINUE; END IF;

    v_status := henvalt.evaluate_eligibility(v_opportunity_id);
    UPDATE henvalt.opportunities SET status=v_status,updated_at=now()
    WHERE id=v_opportunity_id AND tenant_id=r.tenant_id;

    IF v_status='ELIGIBLE' THEN
      v_recovery_id := henvalt.create_recovery_sequence(v_opportunity_id);
      PERFORM henvalt.create_intervention_and_enqueue(
        v_recovery_id,'EMAIL'::henvalt.channel_type,1,now(),'browse_abandonment',
        (SELECT c.email FROM henvalt.customers c WHERE c.id=r.customer_id AND c.tenant_id=r.tenant_id),
        v_key||':intervention:EMAIL:1',
        (SELECT o.correlation_id FROM henvalt.opportunities o WHERE o.id=v_opportunity_id)
      );
      v_queued := v_queued+1;
    ELSE
      v_suppressed := v_suppressed+1;
    END IF;
  END LOOP;

  RETURN jsonb_build_object(
    'created',v_created,'queued',v_queued,'suppressed_or_ineligible',v_suppressed,
    'inactivity_minutes',greatest(30,least(coalesce(p_inactivity_minutes,60),1440))
  );
END;
$function$;

REVOKE ALL ON FUNCTION henvalt.process_browse_abandonment_candidates(integer,integer,integer) FROM PUBLIC, anon, authenticated;

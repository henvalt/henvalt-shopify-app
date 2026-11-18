-- HENVALT exact-store pixel cart/browse recovered-order attribution V2.
-- PREPARATION ONLY. Provider acceptance/delivery is a touch, never revenue.
-- A paid same-store Shopify order and exact customer match are still required.
BEGIN;

-- Keep checkout attribution lineage intact while permitting a separate pixel lineage.
ALTER TABLE henvalt.shopify_recovery_attributions_v2
  ALTER COLUMN checkout_identity_id DROP NOT NULL,
  ALTER COLUMN send_attempt_id DROP NOT NULL,
  ADD COLUMN IF NOT EXISTS pixel_send_attempt_id uuid;

ALTER TABLE henvalt.shopify_recovery_attributions_v2
  ADD CONSTRAINT shopify_recovery_attributions_v2_pixel_attempt_fkey
    FOREIGN KEY(pixel_send_attempt_id,tenant_id,shopify_connection_id)
    REFERENCES henvalt.shopify_pixel_send_attempts_v2(id,tenant_id,shopify_connection_id)
    ON UPDATE RESTRICT ON DELETE RESTRICT,
  ADD CONSTRAINT shopify_recovery_attributions_v2_source_shape_check
    CHECK (
      (checkout_identity_id IS NOT NULL AND send_attempt_id IS NOT NULL
       AND pixel_send_attempt_id IS NULL)
      OR
      (checkout_identity_id IS NULL AND send_attempt_id IS NULL
       AND pixel_send_attempt_id IS NOT NULL)
    );

CREATE UNIQUE INDEX IF NOT EXISTS shopify_recovery_attributions_v2_pixel_attempt_uidx
  ON henvalt.shopify_recovery_attributions_v2(shopify_connection_id,pixel_send_attempt_id)
  WHERE pixel_send_attempt_id IS NOT NULL;

COMMENT ON COLUMN henvalt.shopify_recovery_attributions_v2.pixel_send_attempt_id IS
  'Exact-store cart/browse pixel send lineage. Checkout identity and legacy send-attempt fields remain NULL for this source.';

CREATE OR REPLACE FUNCTION henvalt.evaluate_shopify_pixel_recovery_attribution_v2(
  p_order_identity_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_order henvalt.shopify_order_identity_v2%rowtype;
  v_policy henvalt.shopify_recovery_attribution_policies_v2%rowtype;
  v_attempt_id uuid;
  v_opportunity_id uuid;
  v_touch_at timestamptz;
  v_refunded numeric(18,4):=0;
  v_net numeric(18,4):=0;
  v_attribution_id uuid;
BEGIN
  SELECT * INTO v_order
  FROM henvalt.shopify_order_identity_v2
  WHERE id=p_order_identity_id
  FOR UPDATE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('accepted',false,'code','ORDER_NOT_FOUND');
  END IF;

  SELECT id INTO v_attribution_id
  FROM henvalt.shopify_recovery_attributions_v2
  WHERE tenant_id=v_order.tenant_id
    AND shopify_connection_id=v_order.shopify_connection_id
    AND order_identity_id=v_order.id;
  IF FOUND THEN
    PERFORM henvalt.reconcile_shopify_recovery_attribution_v2(v_attribution_id);
    RETURN jsonb_build_object('accepted',true,'status','RECONCILED',
      'attribution_id',v_attribution_id);
  END IF;

  SELECT * INTO v_policy
  FROM henvalt.shopify_recovery_attribution_policies_v2
  WHERE tenant_id=v_order.tenant_id
    AND shopify_connection_id=v_order.shopify_connection_id
    AND enabled IS TRUE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('accepted',false,'code','ATTRIBUTION_POLICY_NOT_CONFIGURED');
  END IF;

  -- Do not compete with checkout attribution or infer identity from a browser/session.
  IF v_order.checkout_match_status<>'NO_CHECKOUT_TOKEN'
     OR v_order.checkout_token IS NOT NULL
     OR v_order.customer_identity_id IS NULL
     OR v_order.ordered_at IS NULL
     OR v_order.total_value IS NULL OR v_order.total_value<=0
     OR v_order.currency IS NULL
     OR length(v_order.currency)<>3
     OR v_order.currency ~ '[^A-Z]'
     OR v_order.cancelled_at IS NOT NULL
     OR v_order.financial_status NOT IN ('paid','partially_refunded') THEN
    RETURN jsonb_build_object('accepted',false,'code','ORDER_NOT_PIXEL_ATTRIBUTABLE');
  END IF;

  -- A signed, reconciled provider event is required. MailerSend delivery alone
  -- is never counted as recovered revenue; it only establishes the recovery touch.
  SELECT eligible.pixel_send_attempt_id,eligible.opportunity_id,eligible.touch_at
    INTO v_attempt_id,v_opportunity_id,v_touch_at
  FROM (
    SELECT
      a.id AS pixel_send_attempt_id,
      o.id AS opportunity_id,
      CASE
        WHEN v_policy.require_delivery_confirmation IS TRUE THEN provider_touch.delivered_at
        ELSE COALESCE(provider_touch.sent_at,provider_touch.delivered_at)
      END AS touch_at
    FROM henvalt.shopify_pixel_send_attempts_v2 a
    JOIN henvalt.shopify_recovery_opportunity_v2 o
      ON o.id=a.opportunity_id
     AND o.tenant_id=a.tenant_id
     AND o.shopify_connection_id=a.shopify_connection_id
    JOIN henvalt.shopify_pixel_recovery_candidate_v2 c
      ON c.id=a.pixel_candidate_id
     AND c.tenant_id=a.tenant_id
     AND c.shopify_connection_id=a.shopify_connection_id
    LEFT JOIN LATERAL (
      SELECT
        min(e.occurred_at) FILTER (WHERE e.event_type='activity.sent') AS sent_at,
        min(e.occurred_at) FILTER (WHERE e.event_type='activity.delivered') AS delivered_at
      FROM henvalt.shopify_mailer_provider_events_v2 e
      WHERE e.pixel_send_attempt_id=a.id
        AND e.tenant_id=a.tenant_id
        AND e.shopify_connection_id=a.shopify_connection_id
        AND e.provider_account_key=a.provider_account_key
        AND e.processing_status='PROCESSED'
        AND e.occurred_at IS NOT NULL
        AND e.event_type IN ('activity.sent','activity.delivered')
    ) provider_touch ON true
    WHERE a.tenant_id=v_order.tenant_id
      AND a.shopify_connection_id=v_order.shopify_connection_id
      AND a.customer_identity_id=v_order.customer_identity_id
      AND c.customer_identity_id=v_order.customer_identity_id
      AND a.status='SUBMITTED'
      AND o.opportunity_type IN ('ABANDONED_CART','BROWSE_ABANDONMENT')
      AND o.status IN ('REVIEW_REQUIRED','CONVERTED')
      AND (
        (v_policy.require_delivery_confirmation IS TRUE
          AND provider_touch.delivered_at IS NOT NULL)
        OR
        (v_policy.require_delivery_confirmation IS FALSE
          AND (provider_touch.sent_at IS NOT NULL OR provider_touch.delivered_at IS NOT NULL))
      )
  ) eligible
  WHERE eligible.touch_at<=v_order.ordered_at
    AND eligible.touch_at>=v_order.ordered_at-make_interval(hours=>v_policy.attribution_window_hours)
  ORDER BY
    CASE WHEN v_policy.touch_model='LAST_ELIGIBLE_TOUCH' THEN eligible.touch_at END DESC,
    CASE WHEN v_policy.touch_model='FIRST_ELIGIBLE_TOUCH' THEN eligible.touch_at END ASC,
    eligible.pixel_send_attempt_id
  LIMIT 1;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('accepted',false,'code','NO_ELIGIBLE_PIXEL_RECOVERY_TOUCH');
  END IF;

  SELECT COALESCE(sum(r.refund_amount),0) INTO v_refunded
  FROM henvalt.shopify_order_refund_adjustments_v2 r
  WHERE r.order_identity_id=v_order.id
    AND r.tenant_id=v_order.tenant_id
    AND r.shopify_connection_id=v_order.shopify_connection_id
    AND r.currency=pg_catalog.upper(v_order.currency);

  IF v_order.financial_status='partially_refunded' AND v_refunded<=0 THEN
    RETURN jsonb_build_object('accepted',false,'code','REFUND_ADJUSTMENTS_PENDING');
  END IF;
  v_net:=GREATEST(v_order.total_value-v_refunded,0);
  IF v_net<=0 THEN
    RETURN jsonb_build_object('accepted',false,'code','NO_NET_RECOVERED_REVENUE');
  END IF;

  INSERT INTO henvalt.shopify_recovery_attributions_v2(
    tenant_id,shopify_connection_id,order_identity_id,checkout_identity_id,
    opportunity_id,send_attempt_id,pixel_send_attempt_id,policy_version,
    touch_model,attribution_window_hours,revenue_basis,gross_recovered_amount,
    refunded_amount,net_recovered_amount,currency,status,attributed_at
  ) VALUES(
    v_order.tenant_id,v_order.shopify_connection_id,v_order.id,NULL,
    v_opportunity_id,NULL,v_attempt_id,v_policy.policy_version,
    v_policy.touch_model,v_policy.attribution_window_hours,v_policy.revenue_basis,
    v_order.total_value,v_refunded,v_net,pg_catalog.upper(v_order.currency),
    'CONFIRMED',pg_catalog.now()
  )
  ON CONFLICT DO NOTHING
  RETURNING id INTO v_attribution_id;

  IF v_attribution_id IS NULL THEN
    SELECT id INTO v_attribution_id
    FROM henvalt.shopify_recovery_attributions_v2
    WHERE tenant_id=v_order.tenant_id
      AND shopify_connection_id=v_order.shopify_connection_id
      AND order_identity_id=v_order.id;
    IF v_attribution_id IS NULL THEN
      RETURN jsonb_build_object('accepted',false,'code','OPPORTUNITY_ALREADY_ATTRIBUTED');
    END IF;
    PERFORM henvalt.reconcile_shopify_recovery_attribution_v2(v_attribution_id);
  END IF;

  UPDATE henvalt.shopify_recovery_opportunity_v2
     SET status='CONVERTED',updated_at=pg_catalog.now()
   WHERE id=v_opportunity_id
     AND tenant_id=v_order.tenant_id
     AND shopify_connection_id=v_order.shopify_connection_id
     AND status='REVIEW_REQUIRED';

  RETURN jsonb_build_object('accepted',true,'status','ATTRIBUTED',
    'attribution_id',v_attribution_id,'pixel_send_attempt_id',v_attempt_id,
    'net_recovered_amount',v_net,'currency',pg_catalog.upper(v_order.currency),
    'checkout_identity_used',false);
END;
$function$;

CREATE OR REPLACE FUNCTION henvalt.evaluate_shopify_pixel_recovery_attribution_order_trigger_v2()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
BEGIN
  PERFORM henvalt.evaluate_shopify_pixel_recovery_attribution_v2(NEW.id);
  RETURN NEW;
END;
$function$;

CREATE OR REPLACE FUNCTION henvalt.evaluate_shopify_pixel_recovery_attribution_provider_event_trigger_v2()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_attempt henvalt.shopify_pixel_send_attempts_v2%rowtype;
  v_order_id uuid;
BEGIN
  IF NEW.processing_status<>'PROCESSED'
     OR NEW.pixel_send_attempt_id IS NULL
     OR NEW.event_type NOT IN ('activity.sent','activity.delivered')
     OR NEW.occurred_at IS NULL THEN
    RETURN NEW;
  END IF;

  SELECT * INTO v_attempt
  FROM henvalt.shopify_pixel_send_attempts_v2
  WHERE id=NEW.pixel_send_attempt_id
    AND tenant_id=NEW.tenant_id
    AND shopify_connection_id=NEW.shopify_connection_id
  FOR UPDATE;
  IF NOT FOUND OR v_attempt.status<>'SUBMITTED' THEN
    RETURN NEW;
  END IF;

  FOR v_order_id IN
    SELECT o.id
    FROM henvalt.shopify_order_identity_v2 o
    WHERE o.tenant_id=v_attempt.tenant_id
      AND o.shopify_connection_id=v_attempt.shopify_connection_id
      AND o.customer_identity_id=v_attempt.customer_identity_id
      AND o.ordered_at>=NEW.occurred_at
      AND o.ordered_at<=NEW.occurred_at+interval '720 hours'
      AND o.checkout_match_status='NO_CHECKOUT_TOKEN'
      AND o.checkout_token IS NULL
  LOOP
    PERFORM henvalt.evaluate_shopify_pixel_recovery_attribution_v2(v_order_id);
  END LOOP;
  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS shopify_pixel_recovery_attribution_order_v2
  ON henvalt.shopify_order_identity_v2;
CREATE TRIGGER shopify_pixel_recovery_attribution_order_v2
AFTER INSERT OR UPDATE OF checkout_match_status,financial_status,cancelled_at,
  total_value,currency,ordered_at,checkout_token,customer_identity_id
ON henvalt.shopify_order_identity_v2
FOR EACH ROW
EXECUTE FUNCTION henvalt.evaluate_shopify_pixel_recovery_attribution_order_trigger_v2();

DROP TRIGGER IF EXISTS shopify_pixel_recovery_attribution_provider_event_v2
  ON henvalt.shopify_mailer_provider_events_v2;
CREATE TRIGGER shopify_pixel_recovery_attribution_provider_event_v2
AFTER UPDATE OF processing_status,pixel_send_attempt_id,event_type,occurred_at
ON henvalt.shopify_mailer_provider_events_v2
FOR EACH ROW
EXECUTE FUNCTION henvalt.evaluate_shopify_pixel_recovery_attribution_provider_event_trigger_v2();

REVOKE ALL ON FUNCTION henvalt.evaluate_shopify_pixel_recovery_attribution_v2(uuid)
  FROM PUBLIC,anon,authenticated,service_role;
REVOKE ALL ON FUNCTION henvalt.evaluate_shopify_pixel_recovery_attribution_order_trigger_v2()
  FROM PUBLIC,anon,authenticated,service_role;
REVOKE ALL ON FUNCTION henvalt.evaluate_shopify_pixel_recovery_attribution_provider_event_trigger_v2()
  FROM PUBLIC,anon,authenticated,service_role;

COMMENT ON FUNCTION henvalt.evaluate_shopify_pixel_recovery_attribution_v2(uuid) IS
  'Attributes a paid exact-store cart/browse order only to a same-customer pixel attempt with a signed, reconciled provider sent/delivered event inside the configured window. Never requires or fabricates a checkout identity.';
COMMIT;

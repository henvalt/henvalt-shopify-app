-- HENVALT exact-store recovered revenue attribution and fee measurement V2.
-- PREPARATION ONLY. No external billing call is made. Attribution is disabled
-- until a merchant policy is explicitly configured for the exact connection.

BEGIN;

ALTER TABLE henvalt.shopify_recovery_send_attempt_v2
  ADD COLUMN IF NOT EXISTS delivered_at timestamptz;

UPDATE henvalt.shopify_recovery_send_attempt_v2 a
   SET delivered_at=e.first_delivered_at
  FROM (
    SELECT send_attempt_id,tenant_id,shopify_connection_id,min(occurred_at) AS first_delivered_at
    FROM henvalt.shopify_mailer_provider_events_v2
    WHERE processing_status='PROCESSED'
      AND event_type='activity.delivered'
      AND occurred_at IS NOT NULL
      AND send_attempt_id IS NOT NULL
    GROUP BY send_attempt_id,tenant_id,shopify_connection_id
  ) e
 WHERE e.send_attempt_id=a.id
   AND e.tenant_id=a.tenant_id
   AND e.shopify_connection_id=a.shopify_connection_id
   AND a.delivered_at IS NULL;

CREATE UNIQUE INDEX IF NOT EXISTS shopify_recovery_intervention_v2_id_tenant_connection_uidx
  ON henvalt.shopify_recovery_intervention_v2(id,tenant_id,shopify_connection_id);

CREATE UNIQUE INDEX IF NOT EXISTS shopify_recovery_opportunity_v2_id_tenant_connection_uidx
  ON henvalt.shopify_recovery_opportunity_v2(id,tenant_id,shopify_connection_id);

CREATE TABLE IF NOT EXISTS henvalt.shopify_recovery_attribution_policies_v2 (
  shopify_connection_id uuid PRIMARY KEY,
  tenant_id uuid NOT NULL,
  enabled boolean NOT NULL DEFAULT false,
  attribution_window_hours integer,
  touch_model text,
  revenue_basis text,
  require_delivery_confirmation boolean,
  policy_version integer NOT NULL DEFAULT 1 CHECK(policy_version>0),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT shopify_recovery_attribution_policies_v2_connection_fkey
    FOREIGN KEY(shopify_connection_id,tenant_id)
    REFERENCES henvalt.shopify_connections(id,tenant_id)
    ON UPDATE RESTRICT ON DELETE RESTRICT,
  CONSTRAINT shopify_recovery_attribution_policies_v2_window_check
    CHECK(attribution_window_hours IS NULL OR attribution_window_hours BETWEEN 1 AND 720),
  CONSTRAINT shopify_recovery_attribution_policies_v2_touch_check
    CHECK(touch_model IS NULL OR touch_model IN ('FIRST_ELIGIBLE_TOUCH','LAST_ELIGIBLE_TOUCH')),
  CONSTRAINT shopify_recovery_attribution_policies_v2_revenue_check
    CHECK(revenue_basis IS NULL OR revenue_basis='SHOPIFY_TOTAL_PRICE'),
  CONSTRAINT shopify_recovery_attribution_policies_v2_enabled_check
    CHECK(NOT enabled OR (
      attribution_window_hours IS NOT NULL AND attribution_window_hours BETWEEN 1 AND 720
      AND touch_model IS NOT NULL AND touch_model IN ('FIRST_ELIGIBLE_TOUCH','LAST_ELIGIBLE_TOUCH')
      AND revenue_basis IS NOT NULL AND revenue_basis='SHOPIFY_TOTAL_PRICE'
      AND require_delivery_confirmation IS NOT NULL
    )),
  CONSTRAINT shopify_recovery_attribution_policies_v2_id_lineage_uidx
    UNIQUE(shopify_connection_id,tenant_id)
);

CREATE TABLE IF NOT EXISTS henvalt.shopify_recovery_attributions_v2 (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id uuid NOT NULL,
  shopify_connection_id uuid NOT NULL,
  order_identity_id uuid NOT NULL,
  checkout_identity_id uuid NOT NULL,
  opportunity_id uuid NOT NULL,
  send_attempt_id uuid NOT NULL,
  policy_version integer NOT NULL CHECK(policy_version>0),
  touch_model text NOT NULL CHECK(touch_model IN ('FIRST_ELIGIBLE_TOUCH','LAST_ELIGIBLE_TOUCH')),
  attribution_window_hours integer NOT NULL CHECK(attribution_window_hours BETWEEN 1 AND 720),
  revenue_basis text NOT NULL CHECK(revenue_basis='SHOPIFY_TOTAL_PRICE'),
  gross_recovered_amount numeric(18,4) NOT NULL CHECK(gross_recovered_amount>=0),
  refunded_amount numeric(18,4) NOT NULL DEFAULT 0 CHECK(refunded_amount>=0),
  net_recovered_amount numeric(18,4) NOT NULL CHECK(net_recovered_amount>=0),
  currency text NOT NULL CHECK(length(currency)=3 AND currency !~ '[^A-Z]'),
  status text NOT NULL CHECK(status IN ('CONFIRMED','REVIEW_REQUIRED','REVERSED')),
  attributed_at timestamptz NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT shopify_recovery_attributions_v2_connection_fkey
    FOREIGN KEY(shopify_connection_id,tenant_id)
    REFERENCES henvalt.shopify_connections(id,tenant_id)
    ON UPDATE RESTRICT ON DELETE RESTRICT,
  CONSTRAINT shopify_recovery_attributions_v2_order_fkey
    FOREIGN KEY(order_identity_id,tenant_id,shopify_connection_id)
    REFERENCES henvalt.shopify_order_identity_v2(id,tenant_id,shopify_connection_id)
    ON UPDATE RESTRICT ON DELETE RESTRICT,
  CONSTRAINT shopify_recovery_attributions_v2_checkout_fkey
    FOREIGN KEY(checkout_identity_id,tenant_id,shopify_connection_id)
    REFERENCES henvalt.shopify_checkout_identity_v2(id,tenant_id,shopify_connection_id)
    ON UPDATE RESTRICT ON DELETE RESTRICT,
  CONSTRAINT shopify_recovery_attributions_v2_opportunity_fkey
    FOREIGN KEY(opportunity_id,tenant_id,shopify_connection_id)
    REFERENCES henvalt.shopify_recovery_opportunity_v2(id,tenant_id,shopify_connection_id)
    ON UPDATE RESTRICT ON DELETE RESTRICT,
  CONSTRAINT shopify_recovery_attributions_v2_attempt_fkey
    FOREIGN KEY(send_attempt_id,tenant_id,shopify_connection_id)
    REFERENCES henvalt.shopify_recovery_send_attempt_v2(id,tenant_id,shopify_connection_id)
    ON UPDATE RESTRICT ON DELETE RESTRICT,
  CONSTRAINT shopify_recovery_attributions_v2_order_uidx
    UNIQUE(shopify_connection_id,order_identity_id),
  CONSTRAINT shopify_recovery_attributions_v2_opportunity_uidx
    UNIQUE(shopify_connection_id,opportunity_id),
  CONSTRAINT shopify_recovery_attributions_v2_id_lineage_uidx
    UNIQUE(id,tenant_id,shopify_connection_id)
);

CREATE INDEX IF NOT EXISTS shopify_recovery_attributions_v2_tenant_status_idx
  ON henvalt.shopify_recovery_attributions_v2(tenant_id,status,attributed_at);

CREATE TABLE IF NOT EXISTS henvalt.shopify_recovery_fee_measurements_v2 (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id uuid NOT NULL,
  shopify_connection_id uuid NOT NULL,
  attribution_id uuid NOT NULL,
  recovered_amount numeric(18,4) NOT NULL CHECK(recovered_amount>=0),
  henvalt_percentage numeric(9,4) NOT NULL CHECK(henvalt_percentage>0 AND henvalt_percentage<=100),
  fee_amount numeric(18,4) NOT NULL CHECK(fee_amount>=0),
  currency text NOT NULL CHECK(length(currency)=3 AND currency !~ '[^A-Z]'),
  status text NOT NULL DEFAULT 'PENDING'
    CHECK(status IN ('PENDING','INVOICED','PAID','VOIDED','CREDIT_REQUIRED','REVIEW_REQUIRED')),
  paddle_transaction_reference text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT shopify_recovery_fee_measurements_v2_connection_fkey
    FOREIGN KEY(shopify_connection_id,tenant_id)
    REFERENCES henvalt.shopify_connections(id,tenant_id)
    ON UPDATE RESTRICT ON DELETE RESTRICT,
  CONSTRAINT shopify_recovery_fee_measurements_v2_attribution_fkey
    FOREIGN KEY(attribution_id,tenant_id,shopify_connection_id)
    REFERENCES henvalt.shopify_recovery_attributions_v2(id,tenant_id,shopify_connection_id)
    ON UPDATE RESTRICT ON DELETE RESTRICT,
  CONSTRAINT shopify_recovery_fee_measurements_v2_attribution_uidx
    UNIQUE(shopify_connection_id,attribution_id)
);

ALTER TABLE henvalt.shopify_recovery_attribution_policies_v2 ENABLE ROW LEVEL SECURITY;
ALTER TABLE henvalt.shopify_recovery_attributions_v2 ENABLE ROW LEVEL SECURITY;
ALTER TABLE henvalt.shopify_recovery_fee_measurements_v2 ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON henvalt.shopify_recovery_attribution_policies_v2 FROM PUBLIC,anon,authenticated,service_role;
REVOKE ALL ON henvalt.shopify_recovery_attributions_v2 FROM PUBLIC,anon,authenticated,service_role;
REVOKE ALL ON henvalt.shopify_recovery_fee_measurements_v2 FROM PUBLIC,anon,authenticated,service_role;

CREATE OR REPLACE FUNCTION henvalt.set_shopify_recovery_attribution_policy_v2(
  p_shopify_connection_id uuid,
  p_enabled boolean,
  p_attribution_window_hours integer,
  p_touch_model text,
  p_revenue_basis text,
  p_require_delivery_confirmation boolean
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE v_tenant_id uuid; v_version integer;
BEGIN
  IF p_shopify_connection_id IS NULL OR p_enabled IS NULL THEN
    RETURN jsonb_build_object('accepted',false,'code','INVALID_POLICY_REQUEST');
  END IF;
  IF p_enabled IS TRUE AND (
    p_attribution_window_hours IS NULL OR p_attribution_window_hours NOT BETWEEN 1 AND 720
    OR p_touch_model IS NULL OR p_touch_model NOT IN ('FIRST_ELIGIBLE_TOUCH','LAST_ELIGIBLE_TOUCH')
    OR p_revenue_basis IS NULL OR p_revenue_basis<>'SHOPIFY_TOTAL_PRICE'
    OR p_require_delivery_confirmation IS NULL
  ) THEN
    RETURN jsonb_build_object('accepted',false,'code','ATTRIBUTION_POLICY_INCOMPLETE');
  END IF;

  SELECT sc.tenant_id INTO v_tenant_id
  FROM henvalt.shopify_connections sc
  WHERE sc.id=p_shopify_connection_id
  FOR UPDATE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('accepted',false,'code','SHOPIFY_CONNECTION_NOT_FOUND');
  END IF;

  INSERT INTO henvalt.shopify_recovery_attribution_policies_v2(
    shopify_connection_id,tenant_id,enabled,attribution_window_hours,
    touch_model,revenue_basis,require_delivery_confirmation,policy_version,updated_at
  ) VALUES(
    p_shopify_connection_id,v_tenant_id,p_enabled,p_attribution_window_hours,
    p_touch_model,p_revenue_basis,p_require_delivery_confirmation,1,pg_catalog.now()
  )
  ON CONFLICT(shopify_connection_id)
  DO UPDATE SET enabled=EXCLUDED.enabled,
    attribution_window_hours=EXCLUDED.attribution_window_hours,
    touch_model=EXCLUDED.touch_model,revenue_basis=EXCLUDED.revenue_basis,
    require_delivery_confirmation=EXCLUDED.require_delivery_confirmation,
    policy_version=henvalt.shopify_recovery_attribution_policies_v2.policy_version+1,
    updated_at=pg_catalog.now()
  RETURNING policy_version INTO v_version;

  RETURN jsonb_build_object('accepted',true,'shopify_connection_id',p_shopify_connection_id,
    'policy_version',v_version,'enabled',p_enabled);
END;
$function$;

CREATE OR REPLACE FUNCTION henvalt.reconcile_shopify_recovery_attribution_v2(p_attribution_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_attr henvalt.shopify_recovery_attributions_v2%rowtype;
  v_order henvalt.shopify_order_identity_v2%rowtype;
  v_refunded numeric(18,4):=0;
  v_net numeric(18,4):=0;
  v_status text:='REVIEW_REQUIRED';
BEGIN
  SELECT * INTO v_attr FROM henvalt.shopify_recovery_attributions_v2
  WHERE id=p_attribution_id FOR UPDATE;
  IF NOT FOUND THEN RETURN; END IF;

  SELECT * INTO v_order FROM henvalt.shopify_order_identity_v2
  WHERE id=v_attr.order_identity_id
    AND tenant_id=v_attr.tenant_id
    AND shopify_connection_id=v_attr.shopify_connection_id
  FOR UPDATE;
  IF NOT FOUND THEN RETURN; END IF;

  SELECT COALESCE(sum(r.refund_amount),0) INTO v_refunded
  FROM henvalt.shopify_order_refund_adjustments_v2 r
  WHERE r.order_identity_id=v_order.id
    AND r.tenant_id=v_attr.tenant_id
    AND r.shopify_connection_id=v_attr.shopify_connection_id
    AND r.currency=pg_catalog.upper(COALESCE(v_order.currency,''));

  IF v_order.cancelled_at IS NOT NULL
     OR v_order.financial_status IN ('voided','cancelled','refunded') THEN
    v_net:=0;
    v_status:='REVERSED';
  ELSIF v_order.financial_status='paid' THEN
    v_net:=GREATEST(COALESCE(v_order.total_value,0)-v_refunded,0);
    v_status:=CASE WHEN v_net>0 THEN 'CONFIRMED' ELSE 'REVERSED' END;
  ELSIF v_order.financial_status='partially_refunded' THEN
    IF v_refunded<=0 THEN
      v_net:=0;
      v_status:='REVIEW_REQUIRED';
    ELSE
      v_net:=GREATEST(COALESCE(v_order.total_value,0)-v_refunded,0);
      v_status:=CASE WHEN v_net>0 THEN 'CONFIRMED' ELSE 'REVERSED' END;
    END IF;
  ELSE
    v_net:=0;
    v_status:='REVIEW_REQUIRED';
  END IF;

  IF v_order.total_value IS NULL OR v_order.total_value<=0
     OR v_order.currency IS NULL OR pg_catalog.upper(v_order.currency)<>v_attr.currency THEN
    v_net:=0;
    v_status:='REVIEW_REQUIRED';
  END IF;

  UPDATE henvalt.shopify_recovery_attributions_v2
     SET gross_recovered_amount=COALESCE(v_order.total_value,gross_recovered_amount),
         refunded_amount=v_refunded,
         net_recovered_amount=v_net,
         status=v_status,
         updated_at=pg_catalog.now()
   WHERE id=v_attr.id;

  UPDATE henvalt.shopify_recovery_fee_measurements_v2 f
     SET recovered_amount=v_net,
         fee_amount=CASE WHEN v_status='CONFIRMED'
           THEN pg_catalog.round(v_net*f.henvalt_percentage/100,4) ELSE 0 END,
         status=CASE
           WHEN v_status='REVIEW_REQUIRED' THEN 'REVIEW_REQUIRED'
           WHEN v_status='REVERSED' AND f.status IN ('INVOICED','PAID','CREDIT_REQUIRED') THEN 'CREDIT_REQUIRED'
           WHEN v_status='REVERSED' THEN 'VOIDED'
           WHEN f.status='CREDIT_REQUIRED' THEN 'CREDIT_REQUIRED'
           WHEN f.status IN ('INVOICED','PAID') AND f.fee_amount<>pg_catalog.round(v_net*f.henvalt_percentage/100,4) THEN 'CREDIT_REQUIRED'
           WHEN f.status IN ('INVOICED','PAID') THEN f.status
           ELSE 'PENDING'
         END,
         updated_at=pg_catalog.now()
   WHERE f.attribution_id=v_attr.id
     AND f.tenant_id=v_attr.tenant_id
     AND f.shopify_connection_id=v_attr.shopify_connection_id;
END;
$function$;

CREATE OR REPLACE FUNCTION henvalt.evaluate_shopify_recovery_attribution_v2(p_order_identity_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_order henvalt.shopify_order_identity_v2%rowtype;
  v_policy henvalt.shopify_recovery_attribution_policies_v2%rowtype;
  v_checkout henvalt.shopify_checkout_identity_v2%rowtype;
  v_opportunity henvalt.shopify_recovery_opportunity_v2%rowtype;
  v_attempt_id uuid;
  v_touch_at timestamptz;
  v_refunded numeric(18,4):=0;
  v_net numeric(18,4):=0;
  v_attribution_id uuid;
BEGIN
  SELECT * INTO v_order FROM henvalt.shopify_order_identity_v2
  WHERE id=p_order_identity_id FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('accepted',false,'code','ORDER_NOT_FOUND'); END IF;

  SELECT id INTO v_attribution_id FROM henvalt.shopify_recovery_attributions_v2
  WHERE shopify_connection_id=v_order.shopify_connection_id
    AND order_identity_id=v_order.id;
  IF FOUND THEN
    PERFORM henvalt.reconcile_shopify_recovery_attribution_v2(v_attribution_id);
    RETURN jsonb_build_object('accepted',true,'status','RECONCILED','attribution_id',v_attribution_id);
  END IF;

  SELECT * INTO v_policy FROM henvalt.shopify_recovery_attribution_policies_v2
  WHERE shopify_connection_id=v_order.shopify_connection_id
    AND tenant_id=v_order.tenant_id AND enabled IS TRUE;
  IF NOT FOUND THEN RETURN jsonb_build_object('accepted',false,'code','ATTRIBUTION_POLICY_NOT_CONFIGURED'); END IF;

  IF v_order.checkout_match_status<>'MATCHED'
     OR v_order.checkout_token IS NULL
     OR v_order.ordered_at IS NULL
     OR v_order.total_value IS NULL OR v_order.total_value<=0
     OR v_order.currency IS NULL
     OR length(v_order.currency)<>3
     OR v_order.currency ~ '[^A-Z]'
     OR v_order.cancelled_at IS NOT NULL
     OR v_order.financial_status IS NULL
     OR v_order.financial_status NOT IN ('paid','partially_refunded') THEN
    RETURN jsonb_build_object('accepted',false,'code','ORDER_NOT_ATTRIBUTABLE');
  END IF;

  SELECT * INTO v_checkout
  FROM henvalt.shopify_checkout_identity_v2 c
  WHERE c.id IN (
    SELECT o.checkout_identity_id
    FROM henvalt.shopify_recovery_opportunity_v2 o
    WHERE o.tenant_id=v_order.tenant_id
      AND o.shopify_connection_id=v_order.shopify_connection_id
  )
    AND c.tenant_id=v_order.tenant_id
    AND c.shopify_connection_id=v_order.shopify_connection_id
    AND c.shopify_checkout_token=v_order.checkout_token
  LIMIT 1;
  IF NOT FOUND THEN RETURN jsonb_build_object('accepted',false,'code','MATCHED_CHECKOUT_NOT_FOUND'); END IF;

  SELECT * INTO v_opportunity
  FROM henvalt.shopify_recovery_opportunity_v2 o
  WHERE o.tenant_id=v_order.tenant_id
    AND o.shopify_connection_id=v_order.shopify_connection_id
    AND o.checkout_identity_id=v_checkout.id
    AND o.status IN ('CONTACT_RESOLUTION_PENDING','CONVERTED')
    AND (o.customer_identity_id IS NULL OR o.customer_identity_id=v_checkout.customer_identity_id)
    AND (v_order.customer_identity_id IS NULL OR v_order.customer_identity_id=v_checkout.customer_identity_id)
  ORDER BY o.created_at DESC LIMIT 1;
  IF NOT FOUND THEN RETURN jsonb_build_object('accepted',false,'code','RECOVERY_OPPORTUNITY_NOT_FOUND'); END IF;

  SELECT a.id,
    CASE WHEN v_policy.require_delivery_confirmation IS TRUE THEN a.delivered_at ELSE a.submitted_at END
  INTO v_attempt_id,v_touch_at
  FROM henvalt.shopify_recovery_intervention_v2 i
  JOIN henvalt.shopify_recovery_send_attempt_v2 a
    ON a.intervention_id=i.id AND a.tenant_id=i.tenant_id
   AND a.shopify_connection_id=i.shopify_connection_id
   AND a.customer_identity_id=i.customer_identity_id
  WHERE i.tenant_id=v_order.tenant_id
    AND i.shopify_connection_id=v_order.shopify_connection_id
    AND i.opportunity_id=v_opportunity.id
    AND a.status IN ('SUBMITTED','DELIVERED')
    AND (
      (v_policy.require_delivery_confirmation IS TRUE AND a.status='DELIVERED' AND a.delivered_at IS NOT NULL AND a.submitted_at IS NOT NULL AND a.delivered_at>=a.submitted_at)
      OR
      (v_policy.require_delivery_confirmation IS FALSE AND a.submitted_at IS NOT NULL)
    )
    AND (CASE WHEN v_policy.require_delivery_confirmation IS TRUE THEN a.delivered_at ELSE a.submitted_at END)<=v_order.ordered_at
    AND (CASE WHEN v_policy.require_delivery_confirmation IS TRUE THEN a.delivered_at ELSE a.submitted_at END)>=
      v_order.ordered_at-make_interval(hours=>v_policy.attribution_window_hours)
  ORDER BY
    CASE WHEN v_policy.touch_model='LAST_ELIGIBLE_TOUCH'
      THEN CASE WHEN v_policy.require_delivery_confirmation IS TRUE THEN a.delivered_at ELSE a.submitted_at END END DESC,
    CASE WHEN v_policy.touch_model='FIRST_ELIGIBLE_TOUCH'
      THEN CASE WHEN v_policy.require_delivery_confirmation IS TRUE THEN a.delivered_at ELSE a.submitted_at END END ASC,
    a.id
  LIMIT 1;
  IF NOT FOUND THEN RETURN jsonb_build_object('accepted',false,'code','NO_ELIGIBLE_RECOVERY_TOUCH'); END IF;

  SELECT COALESCE(sum(r.refund_amount),0) INTO v_refunded
  FROM henvalt.shopify_order_refund_adjustments_v2 r
  WHERE r.order_identity_id=v_order.id
    AND r.tenant_id=v_order.tenant_id
    AND r.shopify_connection_id=v_order.shopify_connection_id
    AND r.currency=pg_catalog.upper(v_order.currency);
  v_net:=GREATEST(v_order.total_value-v_refunded,0);
  IF v_order.financial_status='partially_refunded' AND v_refunded<=0 THEN
    RETURN jsonb_build_object('accepted',false,'code','REFUND_ADJUSTMENTS_PENDING');
  END IF;
  IF v_net<=0 THEN RETURN jsonb_build_object('accepted',false,'code','NO_NET_RECOVERED_REVENUE'); END IF;

  INSERT INTO henvalt.shopify_recovery_attributions_v2(
    tenant_id,shopify_connection_id,order_identity_id,checkout_identity_id,
    opportunity_id,send_attempt_id,policy_version,touch_model,
    attribution_window_hours,revenue_basis,gross_recovered_amount,
    refunded_amount,net_recovered_amount,currency,status,attributed_at
  ) VALUES(
    v_order.tenant_id,v_order.shopify_connection_id,v_order.id,v_checkout.id,
    v_opportunity.id,v_attempt_id,v_policy.policy_version,v_policy.touch_model,
    v_policy.attribution_window_hours,v_policy.revenue_basis,v_order.total_value,
    v_refunded,v_net,pg_catalog.upper(v_order.currency),'CONFIRMED',pg_catalog.now()
  )
  ON CONFLICT DO NOTHING
  RETURNING id INTO v_attribution_id;

  IF v_attribution_id IS NULL THEN
    SELECT id INTO v_attribution_id FROM henvalt.shopify_recovery_attributions_v2
    WHERE shopify_connection_id=v_order.shopify_connection_id AND order_identity_id=v_order.id;
    IF v_attribution_id IS NULL THEN
      RETURN jsonb_build_object('accepted',false,'code','OPPORTUNITY_ALREADY_ATTRIBUTED');
    END IF;
    PERFORM henvalt.reconcile_shopify_recovery_attribution_v2(v_attribution_id);
  END IF;

  RETURN jsonb_build_object('accepted',v_attribution_id IS NOT NULL,
    'status','ATTRIBUTED','attribution_id',v_attribution_id,
    'send_attempt_id',v_attempt_id,'net_recovered_amount',v_net,'currency',pg_catalog.upper(v_order.currency));
END;
$function$;

CREATE OR REPLACE FUNCTION henvalt.create_shopify_recovery_fee_measurement_v2()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE v_billing record;
BEGIN
  IF NEW.status<>'CONFIRMED' OR NEW.net_recovered_amount<=0 THEN RETURN NEW; END IF;
  SELECT ba.status::text AS billing_status,ba.test_mode,ba.henvalt_percentage,
         pg_catalog.upper(pg_catalog.btrim(ba.currency::text)) AS billing_currency
  INTO v_billing
  FROM henvalt.billing_accounts ba
  WHERE ba.tenant_id=NEW.tenant_id;
  IF NOT FOUND OR v_billing.billing_status<>'ACTIVE'
     OR v_billing.test_mode IS DISTINCT FROM false
     OR v_billing.henvalt_percentage IS NULL OR v_billing.henvalt_percentage<=0 OR v_billing.henvalt_percentage>100
     OR v_billing.billing_currency<>NEW.currency THEN
    RETURN NEW;
  END IF;

  INSERT INTO henvalt.shopify_recovery_fee_measurements_v2(
    tenant_id,shopify_connection_id,attribution_id,recovered_amount,
    henvalt_percentage,fee_amount,currency,status
  ) VALUES(
    NEW.tenant_id,NEW.shopify_connection_id,NEW.id,NEW.net_recovered_amount,
    v_billing.henvalt_percentage,
    pg_catalog.round(NEW.net_recovered_amount*v_billing.henvalt_percentage/100,4),
    NEW.currency,'PENDING'
  )
  ON CONFLICT(shopify_connection_id,attribution_id) DO NOTHING;
  RETURN NEW;
END;
$function$;

CREATE OR REPLACE FUNCTION henvalt.reconcile_shopify_recovery_attribution_trigger_v2()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE v_attribution_id uuid;
BEGIN
  FOR v_attribution_id IN
    SELECT a.id FROM henvalt.shopify_recovery_attributions_v2 a
    WHERE a.order_identity_id=NEW.order_identity_id
      AND a.tenant_id=NEW.tenant_id
      AND a.shopify_connection_id=NEW.shopify_connection_id
  LOOP
    PERFORM henvalt.reconcile_shopify_recovery_attribution_v2(v_attribution_id);
  END LOOP;
  RETURN NEW;
END;
$function$;

CREATE OR REPLACE FUNCTION henvalt.evaluate_shopify_recovery_attribution_order_trigger_v2()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
BEGIN
  PERFORM henvalt.evaluate_shopify_recovery_attribution_v2(NEW.id);
  RETURN NEW;
END;
$function$;

CREATE OR REPLACE FUNCTION henvalt.evaluate_shopify_recovery_attribution_attempt_trigger_v2()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE v_opportunity_id uuid; v_checkout_token text; v_order_id uuid;
BEGIN
  IF NEW.status NOT IN ('SUBMITTED','DELIVERED') THEN RETURN NEW; END IF;
  SELECT i.opportunity_id,c.shopify_checkout_token
    INTO v_opportunity_id,v_checkout_token
  FROM henvalt.shopify_recovery_intervention_v2 i
  JOIN henvalt.shopify_recovery_opportunity_v2 o
    ON o.id=i.opportunity_id AND o.tenant_id=i.tenant_id
   AND o.shopify_connection_id=i.shopify_connection_id
  JOIN henvalt.shopify_checkout_identity_v2 c
    ON c.id=o.checkout_identity_id AND c.tenant_id=o.tenant_id
   AND c.shopify_connection_id=o.shopify_connection_id
  WHERE i.id=NEW.intervention_id
    AND i.tenant_id=NEW.tenant_id
    AND i.shopify_connection_id=NEW.shopify_connection_id;
  IF v_opportunity_id IS NULL OR v_checkout_token IS NULL THEN RETURN NEW; END IF;

  FOR v_order_id IN
    SELECT o.id FROM henvalt.shopify_order_identity_v2 o
    WHERE o.tenant_id=NEW.tenant_id
      AND o.shopify_connection_id=NEW.shopify_connection_id
      AND o.checkout_token=v_checkout_token
  LOOP
    PERFORM henvalt.evaluate_shopify_recovery_attribution_v2(v_order_id);
  END LOOP;
  RETURN NEW;
END;
$function$;

CREATE OR REPLACE FUNCTION henvalt.capture_shopify_mailer_delivered_at_v2()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
BEGIN
  IF NEW.processing_status='PROCESSED'
     AND NEW.event_type='activity.delivered'
     AND NEW.send_attempt_id IS NOT NULL THEN
    UPDATE henvalt.shopify_recovery_send_attempt_v2
       SET delivered_at=COALESCE(delivered_at,NEW.occurred_at,pg_catalog.now()),
           updated_at=pg_catalog.now()
     WHERE id=NEW.send_attempt_id
       AND tenant_id=NEW.tenant_id
       AND shopify_connection_id=NEW.shopify_connection_id
       AND status IN ('SUBMITTED','DELIVERED','AMBIGUOUS');
  END IF;
  RETURN NEW;
END;
$function$;

CREATE OR REPLACE FUNCTION henvalt.create_missing_shopify_recovery_fee_measurements_v2()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
BEGIN
  IF NEW.status::text='ACTIVE' AND NEW.test_mode IS FALSE
     AND NEW.henvalt_percentage>0 AND NEW.henvalt_percentage<=100 THEN
    INSERT INTO henvalt.shopify_recovery_fee_measurements_v2(
      tenant_id,shopify_connection_id,attribution_id,recovered_amount,
      henvalt_percentage,fee_amount,currency,status
    )
    SELECT a.tenant_id,a.shopify_connection_id,a.id,a.net_recovered_amount,
      NEW.henvalt_percentage,
      pg_catalog.round(a.net_recovered_amount*NEW.henvalt_percentage/100,4),
      a.currency,'PENDING'
    FROM henvalt.shopify_recovery_attributions_v2 a
    WHERE a.tenant_id=NEW.tenant_id AND a.status='CONFIRMED'
      AND a.net_recovered_amount>0
      AND a.currency=pg_catalog.upper(pg_catalog.btrim(NEW.currency::text))
    ON CONFLICT(shopify_connection_id,attribution_id) DO NOTHING;
  END IF;
  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS shopify_recovery_attribution_order_v2 ON henvalt.shopify_order_identity_v2;
CREATE TRIGGER shopify_recovery_attribution_order_v2
AFTER INSERT OR UPDATE OF checkout_match_status,financial_status,cancelled_at,total_value,currency,ordered_at,checkout_token
ON henvalt.shopify_order_identity_v2
FOR EACH ROW EXECUTE FUNCTION henvalt.evaluate_shopify_recovery_attribution_order_trigger_v2();

DROP TRIGGER IF EXISTS shopify_recovery_attribution_attempt_v2 ON henvalt.shopify_recovery_send_attempt_v2;
CREATE TRIGGER shopify_recovery_attribution_attempt_v2
AFTER UPDATE OF status,submitted_at,delivered_at ON henvalt.shopify_recovery_send_attempt_v2
FOR EACH ROW EXECUTE FUNCTION henvalt.evaluate_shopify_recovery_attribution_attempt_trigger_v2();

DROP TRIGGER IF EXISTS shopify_recovery_attribution_fee_v2 ON henvalt.shopify_recovery_attributions_v2;
CREATE TRIGGER shopify_recovery_attribution_fee_v2
AFTER INSERT ON henvalt.shopify_recovery_attributions_v2
FOR EACH ROW EXECUTE FUNCTION henvalt.create_shopify_recovery_fee_measurement_v2();

DROP TRIGGER IF EXISTS shopify_recovery_attribution_refund_reconcile_v2 ON henvalt.shopify_order_refund_adjustments_v2;
CREATE TRIGGER shopify_recovery_attribution_refund_reconcile_v2
AFTER INSERT OR UPDATE ON henvalt.shopify_order_refund_adjustments_v2
FOR EACH ROW EXECUTE FUNCTION henvalt.reconcile_shopify_recovery_attribution_trigger_v2();

DROP TRIGGER IF EXISTS shopify_recovery_attribution_mailer_delivered_at_v2 ON henvalt.shopify_mailer_provider_events_v2;
CREATE TRIGGER shopify_recovery_attribution_mailer_delivered_at_v2
AFTER UPDATE OF processing_status,send_attempt_id,event_type ON henvalt.shopify_mailer_provider_events_v2
FOR EACH ROW EXECUTE FUNCTION henvalt.capture_shopify_mailer_delivered_at_v2();

DROP TRIGGER IF EXISTS shopify_recovery_fee_measurement_billing_v2 ON henvalt.billing_accounts;
CREATE TRIGGER shopify_recovery_fee_measurement_billing_v2
AFTER UPDATE OF status,test_mode,henvalt_percentage,currency ON henvalt.billing_accounts
FOR EACH ROW EXECUTE FUNCTION henvalt.create_missing_shopify_recovery_fee_measurements_v2();

REVOKE ALL ON FUNCTION henvalt.set_shopify_recovery_attribution_policy_v2(uuid,boolean,integer,text,text,boolean)
  FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION henvalt.set_shopify_recovery_attribution_policy_v2(uuid,boolean,integer,text,text,boolean)
  TO service_role;
REVOKE ALL ON FUNCTION henvalt.reconcile_shopify_recovery_attribution_v2(uuid)
  FROM PUBLIC,anon,authenticated,service_role;
REVOKE ALL ON FUNCTION henvalt.evaluate_shopify_recovery_attribution_v2(uuid)
  FROM PUBLIC,anon,authenticated,service_role;
REVOKE ALL ON FUNCTION henvalt.create_shopify_recovery_fee_measurement_v2()
  FROM PUBLIC,anon,authenticated,service_role;
REVOKE ALL ON FUNCTION henvalt.reconcile_shopify_recovery_attribution_trigger_v2()
  FROM PUBLIC,anon,authenticated,service_role;
REVOKE ALL ON FUNCTION henvalt.evaluate_shopify_recovery_attribution_order_trigger_v2()
  FROM PUBLIC,anon,authenticated,service_role;
REVOKE ALL ON FUNCTION henvalt.evaluate_shopify_recovery_attribution_attempt_trigger_v2()
  FROM PUBLIC,anon,authenticated,service_role;
REVOKE ALL ON FUNCTION henvalt.capture_shopify_mailer_delivered_at_v2()
  FROM PUBLIC,anon,authenticated,service_role;
REVOKE ALL ON FUNCTION henvalt.create_missing_shopify_recovery_fee_measurements_v2()
  FROM PUBLIC,anon,authenticated,service_role;

COMMENT ON TABLE henvalt.shopify_recovery_attributions_v2 IS
  'One exact-store recovered order attribution per order, backed by an eligible provider-accepted recovery touch and explicit merchant policy.';
COMMENT ON TABLE henvalt.shopify_recovery_fee_measurements_v2 IS
  'Non-charging performance-fee measurement snapshots. External billing is not invoked by this ledger.';

COMMIT;

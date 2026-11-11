ALTER FUNCTION henvalt.get_recovery_worker_context(uuid)
  RENAME TO get_recovery_worker_context_legacy;

CREATE OR REPLACE FUNCTION henvalt.get_recovery_worker_context(p_intervention_id uuid)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path TO 'henvalt', 'public', 'pg_temp'
AS $function$
DECLARE
  v_context jsonb;
  v_op henvalt.opportunities%ROWTYPE;
  v_shop_active boolean := false;
  v_order_recovered boolean := false;
  v_products jsonb := '[]'::jsonb;
BEGIN
  v_context := henvalt.get_recovery_worker_context_legacy(p_intervention_id);
  IF v_context IS NULL OR v_context->>'context_found'='false' THEN RETURN v_context; END IF;

  SELECT op.* INTO v_op FROM henvalt.opportunities op
  WHERE op.id=(v_context->>'opportunity_id')::uuid
    AND op.tenant_id=(v_context->>'tenant_id')::uuid;

  IF NOT FOUND OR v_op.opportunity_type::text <> 'BROWSE_ABANDONMENT' THEN RETURN v_context; END IF;

  SELECT EXISTS(SELECT 1 FROM henvalt.shopify_connections sc
    WHERE sc.tenant_id=v_op.tenant_id
      AND lower(sc.shop_domain)=lower(v_op.metadata->>'shop_domain')
      AND sc.active=true) INTO v_shop_active;

  SELECT EXISTS(SELECT 1 FROM henvalt.orders o
    WHERE o.tenant_id=v_op.tenant_id AND o.customer_id=v_op.customer_id
      AND o.ordered_at>=v_op.created_at AND lower(coalesce(o.financial_status,''))='paid'
      AND o.cancelled_at IS NULL) INTO v_order_recovered;

  v_products := jsonb_build_array(jsonb_build_object(
    'title',v_op.metadata->>'product_title','product_id',v_op.metadata->>'product_id',
    'variant_id',v_op.metadata->>'variant_id','price',v_op.metadata->>'price_amount',
    'currency',v_op.metadata->>'currency','quantity',1
  ));

  RETURN v_context || jsonb_build_object(
    'checkout_updated_at',v_op.metadata->>'last_activity_at',
    'shop_connection_active',v_shop_active,'order_recovered',v_order_recovered,
    'products',v_products,'destination_url',v_op.metadata->>'destination_url',
    'checkout_url',v_op.metadata->>'destination_url','browse_context',v_op.metadata,
    'recovery_type','BROWSE_ABANDONMENT','opportunity_type','BROWSE_ABANDONMENT',
    'value_at_risk',v_op.value_at_risk,'currency',v_op.currency
  );
END;
$function$;

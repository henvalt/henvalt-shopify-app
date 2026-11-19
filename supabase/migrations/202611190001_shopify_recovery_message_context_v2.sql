-- HENVALT server-resolved recovery message context V2.
-- PREPARATION ONLY. Returns safe copy inputs, never customer data or secrets.
BEGIN;

CREATE OR REPLACE FUNCTION henvalt.resolve_shopify_recovery_message_context_v2(
  p_work_type text,
  p_work_id uuid
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=''
AS $function$
DECLARE
  v_shop_domain text;
  v_opportunity_type text;
BEGIN
  IF current_setting('request.jwt.claim.role',true) IS DISTINCT FROM 'service_role' THEN
    RAISE EXCEPTION 'service_role_required' USING ERRCODE='42501';
  END IF;

  IF p_work_id IS NULL OR p_work_type IS NULL OR p_work_type NOT IN ('CHECKOUT_INTERVENTION','PIXEL_OPPORTUNITY') THEN
    RETURN jsonb_build_object('ready',false,'code','INVALID_MESSAGE_CONTEXT_REQUEST');
  END IF;

  IF p_work_type='CHECKOUT_INTERVENTION' THEN
    SELECT sc.shop_domain,o.opportunity_type
      INTO v_shop_domain,v_opportunity_type
    FROM henvalt.shopify_recovery_intervention_v2 i
    JOIN henvalt.shopify_recovery_opportunity_v2 o
      ON o.id=i.opportunity_id
     AND o.tenant_id=i.tenant_id
     AND o.shopify_connection_id=i.shopify_connection_id
    JOIN henvalt.shopify_checkout_recovery_candidate_v2 c
      ON c.id=o.candidate_id
     AND c.tenant_id=o.tenant_id
     AND c.shopify_connection_id=o.shopify_connection_id
    JOIN henvalt.shopify_checkout_identity_v2 ch
      ON ch.id=o.checkout_identity_id
     AND ch.tenant_id=o.tenant_id
     AND ch.shopify_connection_id=o.shopify_connection_id
    JOIN henvalt.shopify_connections sc
      ON sc.id=i.shopify_connection_id
     AND sc.tenant_id=i.tenant_id
    JOIN henvalt.shopify_app_registry ar
      ON ar.app_key=o.app_key
     AND ar.lifecycle_status='active'
    JOIN henvalt.tenants t
      ON t.id=i.tenant_id
     AND t.status='ACTIVE'
    WHERE i.id=p_work_id
      AND i.status='READY_FOR_AUTHORIZATION'
      AND o.opportunity_type='ABANDONED_CHECKOUT'
      AND o.status='CONTACT_RESOLUTION_PENDING'
      AND c.state='READY_FOR_CONTACT_RESOLUTION'
      AND ch.checkout_status='OPEN'
      AND ch.customer_identity_id=i.customer_identity_id
      AND o.customer_identity_id=i.customer_identity_id
      AND ch.shopify_checkout_token=c.checkout_token
      AND sc.active IS TRUE
      AND sc.app_key=o.app_key
      AND i.customer_identity_id IS NOT NULL
      AND o.customer_identity_id IS NOT NULL;
  ELSE
    SELECT sc.shop_domain,o.opportunity_type
      INTO v_shop_domain,v_opportunity_type
    FROM henvalt.shopify_recovery_opportunity_v2 o
    JOIN henvalt.shopify_pixel_recovery_candidate_v2 c
      ON c.id=o.pixel_candidate_id
     AND c.tenant_id=o.tenant_id
     AND c.shopify_connection_id=o.shopify_connection_id
    JOIN henvalt.shopify_connections sc
      ON sc.id=o.shopify_connection_id
     AND sc.tenant_id=o.tenant_id
    JOIN henvalt.shopify_app_registry ar
      ON ar.app_key=o.app_key
     AND ar.lifecycle_status='active'
    JOIN henvalt.tenants t
      ON t.id=o.tenant_id
     AND t.status='ACTIVE'
    WHERE o.id=p_work_id
      AND o.opportunity_type IN ('ABANDONED_CART','BROWSE_ABANDONMENT')
      AND o.status='REVIEW_REQUIRED'
      AND o.customer_identity_id IS NOT NULL
      AND c.customer_identity_id=o.customer_identity_id
      AND c.status='PROMOTED'
      AND sc.active IS TRUE
      AND sc.app_key=o.app_key
      AND NOT EXISTS (
        SELECT 1 FROM henvalt.shopify_recovery_intervention_v2 i
        WHERE i.opportunity_id=o.id
          AND i.tenant_id=o.tenant_id
          AND i.shopify_connection_id=o.shopify_connection_id
      );
  END IF;

  IF v_shop_domain IS NULL
     OR v_shop_domain !~ '^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?[.]myshopify[.]com
     OR v_opportunity_type IS NULL THEN
    RETURN jsonb_build_object('ready',false,'code','MESSAGE_CONTEXT_NOT_ELIGIBLE');
  END IF;

  RETURN jsonb_build_object(
    'ready',true,
    'shop_domain',v_shop_domain,
    'opportunity_type',v_opportunity_type,
    'message_context_version','recovery-v2-2026-11-19',
    'recipient_pii_returned',false,
    'provider_secrets_returned',false,
    'delivery_authorized',false
  );
END;
$function$;

REVOKE ALL ON FUNCTION henvalt.resolve_shopify_recovery_message_context_v2(text,uuid)
  FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION henvalt.resolve_shopify_recovery_message_context_v2(text,uuid)
  TO service_role;

COMMIT;

     OR v_opportunity_type IS NULL THEN
    RETURN jsonb_build_object('ready',false,'code','MESSAGE_CONTEXT_NOT_ELIGIBLE');
  END IF;

  RETURN jsonb_build_object(
    'ready',true,
    'shop_domain',v_shop_domain,
    'opportunity_type',v_opportunity_type,
    'message_context_version','recovery-v2-2026-11-19',
    'recipient_pii_returned',false,
    'provider_secrets_returned',false,
    'delivery_authorized',false
  );
END;
$function$;

REVOKE ALL ON FUNCTION henvalt.resolve_shopify_recovery_message_context_v2(text,uuid)
  FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION henvalt.resolve_shopify_recovery_message_context_v2(text,uuid)
  TO service_role;

COMMIT;

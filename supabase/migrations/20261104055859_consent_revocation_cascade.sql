CREATE OR REPLACE FUNCTION henvalt.apply_eligibility(
  p_opportunity_id uuid,
  p_status henvalt.opportunity_status
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'pg_catalog', 'henvalt', 'pg_temp'
AS $function$
DECLARE
  v_updated integer;
BEGIN
  IF p_status NOT IN ('ELIGIBLE', 'INELIGIBLE', 'SUPPRESSED', 'EXPIRED') THEN
    RAISE EXCEPTION 'Invalid eligibility status: %', p_status;
  END IF;

  UPDATE henvalt.opportunities
     SET status = p_status,
         updated_at = now()
   WHERE id = p_opportunity_id
     AND (
       status IN ('DETECTED', 'INELIGIBLE', 'SUPPRESSED')
       OR (
         status = 'ELIGIBLE'
         AND p_status IN ('INELIGIBLE', 'SUPPRESSED', 'EXPIRED')
       )
     );

  GET DIAGNOSTICS v_updated = ROW_COUNT;
  RETURN v_updated = 1;
END;
$function$;

CREATE OR REPLACE FUNCTION henvalt.apply_shopify_email_consent_update(
  p_tenant_id uuid,
  p_shopify_customer_id text,
  p_email text,
  p_email_consent boolean,
  p_metadata jsonb DEFAULT '{}'::jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'pg_catalog', 'henvalt', 'pg_temp'
AS $function$
DECLARE
  v_customer_id uuid;
  v_previous_consent boolean;
  v_suppressed_opportunities integer := 0;
  v_cancelled_sequences integer := 0;
  v_cancelled_interventions integer := 0;
  v_rejected_deliveries integer := 0;
BEGIN
  IF p_tenant_id IS NULL OR p_email_consent IS NULL THEN
    RAISE EXCEPTION 'TENANT_AND_EXPLICIT_CONSENT_REQUIRED'
      USING ERRCODE = '22023';
  END IF;

  IF NULLIF(BTRIM(COALESCE(p_shopify_customer_id, '')), '') IS NULL
     AND NULLIF(BTRIM(COALESCE(p_email, '')), '') IS NULL THEN
    RAISE EXCEPTION 'SHOPIFY_CUSTOMER_ID_OR_EMAIL_REQUIRED'
      USING ERRCODE = '22023';
  END IF;

  SELECT c.id, c.email_consent
    INTO v_customer_id, v_previous_consent
    FROM henvalt.customers c
   WHERE c.tenant_id = p_tenant_id
     AND (
       (
         NULLIF(BTRIM(COALESCE(p_shopify_customer_id, '')), '') IS NOT NULL
         AND c.shopify_customer_id = NULLIF(BTRIM(p_shopify_customer_id), '')
       )
       OR (
         NULLIF(BTRIM(COALESCE(p_email, '')), '') IS NOT NULL
         AND LOWER(c.email) = LOWER(BTRIM(p_email))
       )
     )
   ORDER BY
     CASE
       WHEN NULLIF(BTRIM(COALESCE(p_shopify_customer_id, '')), '') IS NOT NULL
        AND c.shopify_customer_id = NULLIF(BTRIM(p_shopify_customer_id), '')
       THEN 0 ELSE 1
     END
   LIMIT 1
   FOR UPDATE;

  v_customer_id := henvalt.upsert_customer(
    p_tenant_id,
    NULLIF(BTRIM(COALESCE(p_shopify_customer_id, '')), ''),
    NULLIF(BTRIM(COALESCE(p_email, '')), ''),
    NULL,
    NULL,
    NULL,
    p_email_consent,
    NULL,
    NULL,
    COALESCE(p_metadata, '{}'::jsonb)
  );

  IF v_customer_id IS NULL THEN
    RAISE EXCEPTION 'SHOPIFY_CUSTOMER_UPSERT_FAILED';
  END IF;

  IF p_email_consent IS FALSE THEN
    UPDATE henvalt.opportunities o
       SET status = 'SUPPRESSED',
           updated_at = now()
     WHERE o.tenant_id = p_tenant_id
       AND o.customer_id = v_customer_id
       AND o.status IN ('DETECTED', 'ELIGIBLE');
    GET DIAGNOSTICS v_suppressed_opportunities = ROW_COUNT;

    UPDATE henvalt.delivery_requests dr
       SET status = 'REJECTED',
           updated_at = now()
     WHERE dr.tenant_id = p_tenant_id
       AND dr.status = 'PENDING'
       AND EXISTS (
         SELECT 1
           FROM henvalt.opportunities o
          WHERE o.id = dr.opportunity_id
            AND o.tenant_id = dr.tenant_id
            AND o.customer_id = v_customer_id
       );
    GET DIAGNOSTICS v_rejected_deliveries = ROW_COUNT;

    UPDATE henvalt.recovery_interventions ri
       SET status = 'CANCELLED',
           cancelled_at = COALESCE(ri.cancelled_at, now()),
           updated_at = now()
     WHERE ri.tenant_id = p_tenant_id
       AND ri.status IN ('PENDING', 'SCHEDULED', 'READY')
       AND EXISTS (
         SELECT 1
           FROM henvalt.opportunities o
          WHERE o.id = ri.opportunity_id
            AND o.tenant_id = ri.tenant_id
            AND o.customer_id = v_customer_id
       );
    GET DIAGNOSTICS v_cancelled_interventions = ROW_COUNT;

    UPDATE henvalt.recovery_sequences rs
       SET status = 'CANCELLED',
           ended_at = COALESCE(rs.ended_at, now()),
           updated_at = now()
     WHERE rs.tenant_id = p_tenant_id
       AND rs.status IN ('SCHEDULED', 'ACTIVE', 'PAUSED')
       AND EXISTS (
         SELECT 1
           FROM henvalt.opportunities o
          WHERE o.id = rs.opportunity_id
            AND o.tenant_id = rs.tenant_id
            AND o.customer_id = v_customer_id
       );
    GET DIAGNOSTICS v_cancelled_sequences = ROW_COUNT;
  END IF;

  INSERT INTO henvalt.audit_log (
    tenant_id,
    event_name,
    entity_type,
    entity_id,
    actor_type,
    actor_reference,
    payload
  ) VALUES (
    p_tenant_id,
    'shopify_email_consent_updated',
    'customer',
    v_customer_id,
    'shopify_webhook',
    'customers_email_marketing_consent/update',
    jsonb_build_object(
      'previous_email_consent', v_previous_consent,
      'email_consent', p_email_consent,
      'suppressed_opportunities', v_suppressed_opportunities,
      'cancelled_sequences', v_cancelled_sequences,
      'cancelled_interventions', v_cancelled_interventions,
      'rejected_pending_deliveries', v_rejected_deliveries
    )
  );

  RETURN jsonb_build_object(
    'customer_id', v_customer_id,
    'email_consent', p_email_consent,
    'suppressed_opportunities', v_suppressed_opportunities,
    'cancelled_sequences', v_cancelled_sequences,
    'cancelled_interventions', v_cancelled_interventions,
    'rejected_pending_deliveries', v_rejected_deliveries
  );
END;
$function$;

REVOKE ALL ON FUNCTION henvalt.apply_shopify_email_consent_update(uuid, text, text, boolean, jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION henvalt.apply_shopify_email_consent_update(uuid, text, text, boolean, jsonb) FROM anon, authenticated;
GRANT EXECUTE ON FUNCTION henvalt.apply_shopify_email_consent_update(uuid, text, text, boolean, jsonb) TO service_role;

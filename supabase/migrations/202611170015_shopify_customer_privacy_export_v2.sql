-- HENVALT exact-store Shopify customer data export V2.
-- PREPARATION ONLY. Returns an exact-store export draft to trusted service code.
-- It does not deliver the export, delete data, or complete the privacy request.
-- Legacy tenant-scoped records are deliberately excluded and force manual review.

BEGIN;

CREATE OR REPLACE FUNCTION henvalt.build_shopify_customer_privacy_export_v2(
  p_receipt_id uuid,
  p_claim_token text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_receipt henvalt.shopify_privacy_webhook_deliveries%ROWTYPE;
  v_customer henvalt.shopify_customer_identity_v2%ROWTYPE;
  v_tenant_id uuid;
  v_connection_id uuid;
  v_claim_hash text;
  v_checkout_ids uuid[];
  v_order_ids uuid[];
  v_opportunity_ids uuid[];
  v_send_attempt_ids uuid[];
  v_result jsonb;
BEGIN
  IF p_receipt_id IS NULL
     OR p_claim_token IS NULL
     OR p_claim_token !~ '^[0-9a-f]{64}$' THEN
    RETURN jsonb_build_object('exported', false, 'code', 'INVALID_CLAIM');
  END IF;

  v_claim_hash := pg_catalog.encode(
    extensions.digest(pg_catalog.convert_to(p_claim_token, 'UTF8'), 'sha256'), 'hex'
  );

  SELECT r.* INTO v_receipt
  FROM henvalt.shopify_privacy_webhook_deliveries r
  JOIN henvalt.shopify_privacy_processing_jobs_v2 j
    ON j.receipt_id = r.id
  JOIN henvalt.shopify_connections sc
    ON sc.id = r.connection_id
   AND sc.tenant_id = r.tenant_id
   AND sc.app_key = r.app_key
   AND sc.shop_domain = r.shop_domain
  WHERE r.id = p_receipt_id
    AND r.topic = 'customers/data_request'
    AND r.connection_id IS NOT NULL
    AND r.tenant_id IS NOT NULL
    AND j.state = 'CLAIMED'
    AND j.lease_until > pg_catalog.now()
    AND j.claim_token_sha256 = v_claim_hash
  FOR UPDATE OF j, r;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('exported', false, 'code', 'CLAIM_OR_STORE_BINDING_INVALID');
  END IF;

  v_tenant_id := v_receipt.tenant_id;
  v_connection_id := v_receipt.connection_id;

  SELECT c.* INTO v_customer
  FROM henvalt.shopify_customer_identity_v2 c
  WHERE c.tenant_id = v_tenant_id
    AND c.shopify_connection_id = v_connection_id
    AND c.external_customer_reference = v_receipt.customer_id
  FOR SHARE;

  IF NOT FOUND THEN
    RETURN jsonb_build_object(
      'exported', true,
      'export_version', '2',
      'generated_at', pg_catalog.now(),
      'shop_domain', v_receipt.shop_domain,
      'shopify_customer_id', v_receipt.customer_id,
      'customer_identity_found', false,
      'records', jsonb_build_object(
        'customer_identity', 'null'::jsonb,
        'sessions', '[]'::jsonb,
        'session_aliases', '[]'::jsonb,
        'pixel_events', '[]'::jsonb,
        'checkouts', '[]'::jsonb,
        'recovery_candidates', '[]'::jsonb,
        'recovery_opportunities', '[]'::jsonb,
        'consent_current', '[]'::jsonb,
        'consent_history', '[]'::jsonb,
        'recovery_interventions', '[]'::jsonb,
        'delivery_attempts', '[]'::jsonb,
        'delivery_permits', '[]'::jsonb,
        'delivery_suppressions', '[]'::jsonb,
        'provider_events', '[]'::jsonb,
        'orders', '[]'::jsonb,
        'refunds', '[]'::jsonb,
        'recovery_attributions', '[]'::jsonb,
        'recovery_fee_measurements', '[]'::jsonb
      ),
      'legacy_scope_review_required', true,
      'completion_eligible', false,
      'review_code', 'NO_EXACT_STORE_IDENTITY_FOUND'
    );
  END IF;

  SELECT COALESCE(array_agg(c.id), ARRAY[]::uuid[])
    INTO v_checkout_ids
  FROM henvalt.shopify_checkout_identity_v2 c
  WHERE c.tenant_id = v_tenant_id
    AND c.shopify_connection_id = v_connection_id
    AND c.customer_identity_id = v_customer.id;

  SELECT COALESCE(array_agg(o.id), ARRAY[]::uuid[])
    INTO v_order_ids
  FROM henvalt.shopify_order_identity_v2 o
  WHERE o.tenant_id = v_tenant_id
    AND o.shopify_connection_id = v_connection_id
    AND o.customer_identity_id = v_customer.id;

  SELECT COALESCE(array_agg(o.id), ARRAY[]::uuid[])
    INTO v_opportunity_ids
  FROM henvalt.shopify_recovery_opportunity_v2 o
  WHERE o.tenant_id = v_tenant_id
    AND o.shopify_connection_id = v_connection_id
    AND (
      o.customer_identity_id = v_customer.id
      OR o.checkout_identity_id = ANY(v_checkout_ids)
    );

  SELECT COALESCE(array_agg(a.id), ARRAY[]::uuid[])
    INTO v_send_attempt_ids
  FROM henvalt.shopify_recovery_send_attempt_v2 a
  WHERE a.tenant_id = v_tenant_id
    AND a.shopify_connection_id = v_connection_id
    AND a.customer_identity_id = v_customer.id;

  SELECT jsonb_build_object(
    'exported', true,
    'export_version', '2',
    'generated_at', pg_catalog.now(),
    'shop_domain', v_receipt.shop_domain,
    'shopify_customer_id', v_receipt.customer_id,
    'customer_identity_found', true,
    'records', jsonb_build_object(
      'customer_identity', jsonb_build_object(
        'external_customer_reference', v_customer.external_customer_reference,
        'first_seen_at', v_customer.first_seen_at,
        'last_seen_at', v_customer.last_seen_at
      ),
      'sessions', COALESCE((
        SELECT jsonb_agg(jsonb_build_object(
          'session_reference', s.session_reference,
          'first_seen_at', s.first_seen_at,
          'last_seen_at', s.last_seen_at
        ) ORDER BY s.first_seen_at)
        FROM henvalt.shopify_session_identity_v2 s
        WHERE s.tenant_id = v_tenant_id
          AND s.shopify_connection_id = v_connection_id
          AND s.customer_identity_id = v_customer.id
      ), '[]'::jsonb),
      'session_aliases', COALESCE((
        SELECT jsonb_agg(jsonb_build_object(
          'alias_reference', a.alias_reference,
          'session_reference', a.session_reference,
          'created_at', a.created_at
        ) ORDER BY a.created_at)
        FROM henvalt.shopify_session_alias_identity_v2 a
        JOIN henvalt.shopify_session_identity_v2 s
          ON s.tenant_id = a.tenant_id
         AND s.shopify_connection_id = a.shopify_connection_id
         AND s.session_reference = a.session_reference
        WHERE s.tenant_id = v_tenant_id
          AND s.shopify_connection_id = v_connection_id
          AND s.customer_identity_id = v_customer.id
      ), '[]'::jsonb),
      'pixel_events', COALESCE((
        SELECT jsonb_agg(jsonb_build_object(
          'source_event_id', e.source_event_id,
          'event_type', e.event_type,
          'event_digest', e.event_digest,
          'occurred_at', e.occurred_at,
          'analytics_processing_allowed', e.analytics_processing_allowed,
          'marketing_allowed', e.marketing_allowed,
          'client_reference', e.client_reference,
          'checkout_reference', e.checkout_reference,
          'payload', e.payload,
          'status', e.status,
          'received_at', e.received_at,
          'processed_at', e.processed_at
        ) ORDER BY e.occurred_at)
        FROM henvalt.shopify_pixel_event_inbox_v2 e
        WHERE e.tenant_id = v_tenant_id
          AND e.shopify_connection_id = v_connection_id
          AND e.customer_reference = v_customer.external_customer_reference
      ), '[]'::jsonb),
      'checkouts', COALESCE((
        SELECT jsonb_agg(jsonb_build_object(
          'shopify_checkout_id', c.shopify_checkout_id,
          'checkout_token', c.checkout_token,
          'session_reference', c.session_reference,
          'checkout_status', c.checkout_status,
          'jurisdiction_country_code', c.jurisdiction_country_code,
          'created_at', c.created_at,
          'updated_at', c.updated_at
        ) ORDER BY c.created_at)
        FROM henvalt.shopify_checkout_identity_v2 c
        WHERE c.id = ANY(v_checkout_ids)
      ), '[]'::jsonb),
      'recovery_candidates', COALESCE((
        SELECT jsonb_agg(jsonb_build_object(
          'checkout_identity_id', c.checkout_identity_id,
          'last_activity_at', c.last_activity_at,
          'eligible_after', c.eligible_after,
          'state', c.state,
          'created_at', c.created_at,
          'updated_at', c.updated_at
        ) ORDER BY c.created_at)
        FROM henvalt.shopify_checkout_recovery_candidate_v2 c
        WHERE c.tenant_id = v_tenant_id
          AND c.shopify_connection_id = v_connection_id
          AND c.checkout_identity_id = ANY(v_checkout_ids)
      ), '[]'::jsonb),
      'recovery_opportunities', COALESCE((
        SELECT jsonb_agg(jsonb_build_object(
          'opportunity_type', o.opportunity_type,
          'status', o.status,
          'value_at_risk', o.value_at_risk,
          'currency', o.currency,
          'created_at', o.created_at,
          'updated_at', o.updated_at
        ) ORDER BY o.created_at)
        FROM henvalt.shopify_recovery_opportunity_v2 o
        WHERE o.id = ANY(v_opportunity_ids)
      ), '[]'::jsonb),
      'consent_current', COALESCE((
        SELECT jsonb_agg(jsonb_build_object(
          'marketing_state', c.marketing_state,
          'opt_in_level', c.opt_in_level,
          'consent_updated_at', c.consent_updated_at,
          'observed_at', c.observed_at
        ) ORDER BY c.observed_at)
        FROM henvalt.shopify_customer_email_consent_v2 c
        WHERE c.tenant_id = v_tenant_id
          AND c.shopify_connection_id = v_connection_id
          AND c.customer_identity_id = v_customer.id
      ), '[]'::jsonb),
      'consent_history', COALESCE((
        SELECT jsonb_agg(jsonb_build_object(
          'marketing_state', c.marketing_state,
          'opt_in_level', c.opt_in_level,
          'consent_updated_at', c.consent_updated_at,
          'received_at', c.received_at
        ) ORDER BY c.received_at)
        FROM henvalt.shopify_customer_email_consent_events_v2 c
        WHERE c.tenant_id = v_tenant_id
          AND c.shopify_connection_id = v_connection_id
          AND c.customer_identity_id = v_customer.id
      ), '[]'::jsonb),
      'recovery_interventions', COALESCE((
        SELECT jsonb_agg(jsonb_build_object(
          'opportunity_id', i.opportunity_id,
          'step_number', i.step_number,
          'status', i.status,
          'scheduled_at', i.scheduled_at,
          'created_at', i.created_at,
          'updated_at', i.updated_at
        ) ORDER BY i.created_at)
        FROM henvalt.shopify_recovery_intervention_v2 i
        WHERE i.tenant_id = v_tenant_id
          AND i.shopify_connection_id = v_connection_id
          AND i.customer_identity_id = v_customer.id
      ), '[]'::jsonb),
      'delivery_attempts', COALESCE((
        SELECT jsonb_agg(jsonb_build_object(
          'intervention_id', a.intervention_id,
          'provider_account_key', a.provider_account_key,
          'provider_message_id', a.provider_message_id,
          'provider_email_id', a.provider_email_id,
          'status', a.status,
          'submitted_at', a.submitted_at,
          'created_at', a.created_at,
          'updated_at', a.updated_at
        ) ORDER BY a.created_at)
        FROM henvalt.shopify_recovery_send_attempt_v2 a
        WHERE a.id = ANY(v_send_attempt_ids)
      ), '[]'::jsonb),
      'delivery_permits', COALESCE((
        SELECT jsonb_agg(jsonb_build_object(
          'intervention_id', p.intervention_id,
          'expires_at', p.expires_at,
          'consumed_at', p.consumed_at,
          'created_at', p.created_at
        ) ORDER BY p.created_at)
        FROM henvalt.shopify_delivery_permits_v2 p
        WHERE p.tenant_id = v_tenant_id
          AND p.shopify_connection_id = v_connection_id
          AND p.customer_identity_id = v_customer.id
      ), '[]'::jsonb),
      'delivery_suppressions', COALESCE((
        SELECT jsonb_agg(jsonb_build_object(
          'suppression_type', s.suppression_type,
          'active', s.active,
          'source_send_attempt_id', s.source_send_attempt_id,
          'created_at', s.created_at,
          'updated_at', s.updated_at
        ) ORDER BY s.created_at)
        FROM henvalt.shopify_delivery_suppressions_v2 s
        WHERE s.tenant_id = v_tenant_id
          AND s.shopify_connection_id = v_connection_id
          AND s.customer_identity_id = v_customer.id
      ), '[]'::jsonb),
      'provider_events', COALESCE((
        SELECT jsonb_agg(jsonb_build_object(
          'provider_event_id', e.provider_event_id,
          'event_type', e.event_type,
          'occurred_at', e.occurred_at,
          'processing_status', e.processing_status,
          'created_at', e.created_at
        ) ORDER BY e.created_at)
        FROM henvalt.shopify_mailer_provider_events_v2 e
        WHERE e.tenant_id = v_tenant_id
          AND e.shopify_connection_id = v_connection_id
          AND e.send_attempt_id = ANY(v_send_attempt_ids)
      ), '[]'::jsonb),
      'orders', COALESCE((
        SELECT jsonb_agg(jsonb_build_object(
          'shopify_order_id', o.shopify_order_id,
          'total_value', o.total_value,
          'currency', o.currency,
          'financial_status', o.financial_status,
          'ordered_at', o.ordered_at,
          'cancelled_at', o.cancelled_at,
          'checkout_match_status', o.checkout_match_status,
          'created_at', o.created_at,
          'updated_at', o.updated_at
        ) ORDER BY o.created_at)
        FROM henvalt.shopify_order_identity_v2 o
        WHERE o.id = ANY(v_order_ids)
      ), '[]'::jsonb),
      'refunds', COALESCE((
        SELECT jsonb_agg(jsonb_build_object(
          'shopify_order_id', o.shopify_order_id,
          'shopify_refund_id', r.shopify_refund_id,
          'refund_amount', r.refund_amount,
          'currency', r.currency,
          'refunded_at', r.refunded_at
        ) ORDER BY r.refunded_at)
        FROM henvalt.shopify_order_refund_adjustments_v2 r
        JOIN henvalt.shopify_order_identity_v2 o
          ON o.id = r.order_identity_id
         AND o.tenant_id = r.tenant_id
         AND o.shopify_connection_id = r.shopify_connection_id
        WHERE r.tenant_id = v_tenant_id
          AND r.shopify_connection_id = v_connection_id
          AND r.order_identity_id = ANY(v_order_ids)
      ), '[]'::jsonb),
      'recovery_attributions', COALESCE((
        SELECT jsonb_agg(jsonb_build_object(
          'shopify_order_id', o.shopify_order_id,
          'opportunity_id', a.opportunity_id,
          'gross_recovered_amount', a.gross_recovered_amount,
          'refunded_amount', a.refunded_amount,
          'net_recovered_amount', a.net_recovered_amount,
          'currency', a.currency,
          'status', a.status,
          'attributed_at', a.attributed_at
        ) ORDER BY a.attributed_at)
        FROM henvalt.shopify_recovery_attributions_v2 a
        JOIN henvalt.shopify_order_identity_v2 o
          ON o.id = a.order_identity_id
         AND o.tenant_id = a.tenant_id
         AND o.shopify_connection_id = a.shopify_connection_id
        WHERE a.tenant_id = v_tenant_id
          AND a.shopify_connection_id = v_connection_id
          AND a.order_identity_id = ANY(v_order_ids)
      ), '[]'::jsonb),
      'recovery_fee_measurements', COALESCE((
        SELECT jsonb_agg(jsonb_build_object(
          'recovered_amount', f.recovered_amount,
          'henvalt_percentage', f.henvalt_percentage,
          'fee_amount', f.fee_amount,
          'currency', f.currency,
          'status', f.status,
          'created_at', f.created_at,
          'updated_at', f.updated_at
        ) ORDER BY f.created_at)
        FROM henvalt.shopify_recovery_fee_measurements_v2 f
        WHERE f.tenant_id = v_tenant_id
          AND f.shopify_connection_id = v_connection_id
          AND f.attribution_id IN (
            SELECT a.id
            FROM henvalt.shopify_recovery_attributions_v2 a
            WHERE a.tenant_id = v_tenant_id
              AND a.shopify_connection_id = v_connection_id
              AND a.order_identity_id = ANY(v_order_ids)
          )
      ), '[]'::jsonb)
    ),
    'legacy_scope_review_required', true,
    'completion_eligible', false,
    'review_code', 'LEGACY_TENANT_SCOPED_RECORDS_NOT_INCLUDED',
    'scope_notice', 'This draft includes only records positively linked to the exact Shopify connection and customer identity. Historical tenant-scoped records without immutable store lineage are excluded and require separate review before this request can be completed.'
  )
  INTO v_result;

  RETURN v_result;
END;
$function$;

REVOKE ALL ON FUNCTION henvalt.build_shopify_customer_privacy_export_v2(uuid,text)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION henvalt.build_shopify_customer_privacy_export_v2(uuid,text)
  TO service_role;

COMMENT ON FUNCTION henvalt.build_shopify_customer_privacy_export_v2(uuid,text) IS
  'Returns an exact-store V2 customer privacy export draft for a live leased request. Does not deliver or complete the request; legacy tenant-scoped data requires manual review.';

COMMIT;

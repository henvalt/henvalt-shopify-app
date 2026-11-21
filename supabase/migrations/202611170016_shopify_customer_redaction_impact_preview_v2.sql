-- HENVALT exact-store customer privacy redaction impact preview V2.
-- PREPARATION ONLY: read-only impact inventory. No deletion, anonymization,
-- suppression retention, receipt completion, or production policy decision.

BEGIN;

CREATE OR REPLACE FUNCTION henvalt.preview_shopify_customer_redaction_v2(
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
  v_claim_hash text;
  v_checkout_ids uuid[];
  v_order_ids uuid[];
  v_opportunity_ids uuid[];
  v_attempt_ids uuid[];
  v_counts jsonb;
BEGIN
  IF p_receipt_id IS NULL
     OR p_claim_token IS NULL
     OR p_claim_token !~ '^[0-9a-f]{64}$' THEN
    RETURN jsonb_build_object('previewed', false, 'code', 'INVALID_CLAIM');
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
    AND r.topic IN ('customers/data_request', 'customers/redact')
    AND r.connection_id IS NOT NULL
    AND r.tenant_id IS NOT NULL
    AND r.customer_id IS NOT NULL
    AND j.state = 'CLAIMED'
    AND j.lease_until > pg_catalog.now()
    AND j.claim_token_sha256 = v_claim_hash
  FOR UPDATE OF j, r;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('previewed', false, 'code', 'CLAIM_OR_STORE_BINDING_INVALID');
  END IF;

  SELECT c.* INTO v_customer
  FROM henvalt.shopify_customer_identity_v2 c
  WHERE c.tenant_id = v_receipt.tenant_id
    AND c.shopify_connection_id = v_receipt.connection_id
    AND c.external_customer_reference = v_receipt.customer_id
  FOR SHARE;

  IF NOT FOUND THEN
    RETURN jsonb_build_object(
      'previewed', true,
      'operation', 'CUSTOMER_REDACTION_IMPACT_PREVIEW',
      'shop_domain', v_receipt.shop_domain,
      'customer_identity_found', false,
      'exact_store_scope_confirmed', true,
      'legacy_scope_review_required', true,
      'safe_to_execute', false,
      'reason', 'NO_EXACT_STORE_CUSTOMER_IDENTITY; legacy records cannot be inferred'
    );
  END IF;

  SELECT COALESCE(pg_catalog.array_agg(c.id), ARRAY[]::uuid[])
    INTO v_checkout_ids
  FROM henvalt.shopify_checkout_identity_v2 c
  WHERE c.tenant_id = v_receipt.tenant_id
    AND c.shopify_connection_id = v_receipt.connection_id
    AND c.customer_identity_id = v_customer.id;

  SELECT COALESCE(pg_catalog.array_agg(o.id), ARRAY[]::uuid[])
    INTO v_order_ids
  FROM henvalt.shopify_order_identity_v2 o
  WHERE o.tenant_id = v_receipt.tenant_id
    AND o.shopify_connection_id = v_receipt.connection_id
    AND o.customer_identity_id = v_customer.id;

  SELECT COALESCE(pg_catalog.array_agg(o.id), ARRAY[]::uuid[])
    INTO v_opportunity_ids
  FROM henvalt.shopify_recovery_opportunity_v2 o
  WHERE o.tenant_id = v_receipt.tenant_id
    AND o.shopify_connection_id = v_receipt.connection_id
    AND (o.customer_identity_id = v_customer.id OR o.checkout_identity_id = ANY(v_checkout_ids));

  SELECT COALESCE(pg_catalog.array_agg(a.id), ARRAY[]::uuid[])
    INTO v_attempt_ids
  FROM henvalt.shopify_recovery_send_attempt_v2 a
  WHERE a.tenant_id = v_receipt.tenant_id
    AND a.shopify_connection_id = v_receipt.connection_id
    AND a.customer_identity_id = v_customer.id;

  SELECT pg_catalog.jsonb_build_object(
    'customer_identity', 1,
    'sessions', (
      SELECT count(*) FROM henvalt.shopify_session_identity_v2 s
      WHERE s.tenant_id=v_receipt.tenant_id AND s.shopify_connection_id=v_receipt.connection_id
        AND s.customer_identity_id=v_customer.id
    ),
    'session_aliases', (
      SELECT count(*) FROM henvalt.shopify_session_alias_identity_v2 a
      JOIN henvalt.shopify_session_identity_v2 s
        ON s.tenant_id=a.tenant_id AND s.shopify_connection_id=a.shopify_connection_id
       AND s.session_reference=a.session_reference
      WHERE s.tenant_id=v_receipt.tenant_id AND s.shopify_connection_id=v_receipt.connection_id
        AND s.customer_identity_id=v_customer.id
    ),
    'pixel_events', (
      SELECT count(*) FROM henvalt.shopify_pixel_event_inbox_v2 e
      WHERE e.tenant_id=v_receipt.tenant_id AND e.shopify_connection_id=v_receipt.connection_id
        AND e.customer_reference=v_receipt.customer_id
    ),
    'checkouts', pg_catalog.cardinality(v_checkout_ids),
    'recovery_candidates', (
      SELECT count(*) FROM henvalt.shopify_checkout_recovery_candidate_v2 c
      WHERE c.tenant_id=v_receipt.tenant_id AND c.shopify_connection_id=v_receipt.connection_id
        AND c.checkout_identity_id=ANY(v_checkout_ids)
    ),
    'recovery_opportunities', pg_catalog.cardinality(v_opportunity_ids),
    'consent_current', (
      SELECT count(*) FROM henvalt.shopify_customer_email_consent_v2 c
      WHERE c.tenant_id=v_receipt.tenant_id AND c.shopify_connection_id=v_receipt.connection_id
        AND c.customer_identity_id=v_customer.id
    ),
    'consent_history', (
      SELECT count(*) FROM henvalt.shopify_customer_email_consent_events_v2 c
      WHERE c.tenant_id=v_receipt.tenant_id AND c.shopify_connection_id=v_receipt.connection_id
        AND c.customer_identity_id=v_customer.id
    ),
    'recovery_interventions', (
      SELECT count(*) FROM henvalt.shopify_recovery_intervention_v2 i
      WHERE i.tenant_id=v_receipt.tenant_id AND i.shopify_connection_id=v_receipt.connection_id
        AND i.customer_identity_id=v_customer.id
    ),
    'delivery_permits', (
      SELECT count(*) FROM henvalt.shopify_delivery_permits_v2 p
      WHERE p.tenant_id=v_receipt.tenant_id AND p.shopify_connection_id=v_receipt.connection_id
        AND p.customer_identity_id=v_customer.id
    ),
    'delivery_attempts', pg_catalog.cardinality(v_attempt_ids),
    'delivery_suppressions', (
      SELECT count(*) FROM henvalt.shopify_delivery_suppressions_v2 s
      WHERE s.tenant_id=v_receipt.tenant_id AND s.shopify_connection_id=v_receipt.connection_id
        AND s.customer_identity_id=v_customer.id
    ),
    'provider_events', (
      SELECT count(*) FROM henvalt.shopify_mailer_provider_events_v2 e
      WHERE e.tenant_id=v_receipt.tenant_id AND e.shopify_connection_id=v_receipt.connection_id
        AND e.send_attempt_id=ANY(v_attempt_ids)
    ),
    'cost_reservations', (
      SELECT count(*) FROM henvalt.shopify_delivery_cost_reservations_v2 c
      WHERE c.tenant_id=v_receipt.tenant_id AND c.shopify_connection_id=v_receipt.connection_id
        AND c.send_attempt_id=ANY(v_attempt_ids)
    ),
    'orders', pg_catalog.cardinality(v_order_ids),
    'refunds', (
      SELECT count(*) FROM henvalt.shopify_order_refund_adjustments_v2 r
      WHERE r.tenant_id=v_receipt.tenant_id AND r.shopify_connection_id=v_receipt.connection_id
        AND r.order_identity_id=ANY(v_order_ids)
    ),
    'attributions', (
      SELECT count(*) FROM henvalt.shopify_recovery_attributions_v2 a
      WHERE a.tenant_id=v_receipt.tenant_id AND a.shopify_connection_id=v_receipt.connection_id
        AND a.order_identity_id=ANY(v_order_ids)
    ),
    'fee_measurements', (
      SELECT count(*) FROM henvalt.shopify_recovery_fee_measurements_v2 f
      WHERE f.tenant_id=v_receipt.tenant_id AND f.shopify_connection_id=v_receipt.connection_id
        AND f.attribution_id IN (
          SELECT a.id FROM henvalt.shopify_recovery_attributions_v2 a
          WHERE a.tenant_id=v_receipt.tenant_id AND a.shopify_connection_id=v_receipt.connection_id
            AND a.order_identity_id=ANY(v_order_ids)
        )
    )
  ) INTO v_counts;

  RETURN pg_catalog.jsonb_build_object(
    'previewed', true,
    'operation', 'CUSTOMER_REDACTION_IMPACT_PREVIEW',
    'shop_domain', v_receipt.shop_domain,
    'customer_identity_found', true,
    'exact_store_scope_confirmed', true,
    'record_counts', v_counts,
    'preservation_requirements', pg_catalog.jsonb_build_object(
      'cost_reservations_must_be_preserved', true,
      'order_refund_and_attribution_facts_require_retention_review', true,
      'suppression_fingerprint_retention_requires_approved_policy', true,
      'provider_event_audit_references_require_fk_safe_detachment', true
    ),
    'legacy_scope_review_required', true,
    'legacy_rows_included', false,
    'safe_to_execute', false,
    'execution_blockers', pg_catalog.jsonb_build_array(
      'LEGACY_TENANT_SCOPED_ROWS_NOT_RECONCILED',
      'RETENTION_POLICY_NOT_APPROVED',
      'SUPPRESSION_RETENTION_POLICY_NOT_APPROVED',
      'COST_LEDGER_DETACHMENT_NOT_IMPLEMENTED',
      'PROVIDER_AUDIT_FK_DETACHMENT_NOT_IMPLEMENTED'
    ),
    'mutations_performed', false
  );
END;
$function$;

REVOKE ALL ON FUNCTION henvalt.preview_shopify_customer_redaction_v2(uuid,text)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION henvalt.preview_shopify_customer_redaction_v2(uuid,text)
  TO service_role;

COMMENT ON FUNCTION henvalt.preview_shopify_customer_redaction_v2(uuid,text) IS
  'Read-only exact-store customer redaction impact inventory. Never deletes, anonymizes, completes a request or selects a retention policy.';

COMMIT;

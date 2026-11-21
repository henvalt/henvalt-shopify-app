-- HENVALT cart/browse delivery policy and eligibility assessment V2.
-- PREPARATION ONLY. No policy rows are seeded and no delivery capability is issued.
-- A policy row requires an externally reviewed legal reference before activation.

BEGIN;

CREATE TABLE IF NOT EXISTS henvalt.shopify_pixel_delivery_jurisdiction_policy_v2 (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  country_code text NOT NULL CHECK (country_code ~ '^[A-Z]{2}$'),
  region_code text,
  policy_version text NOT NULL CHECK (length(btrim(policy_version)) BETWEEN 1 AND 40),
  policy_status text NOT NULL DEFAULT 'DRAFT'
    CHECK (policy_status IN ('DRAFT','APPROVED','SUSPENDED','EXPIRED')),
  legal_review_reference text NOT NULL
    CHECK (length(btrim(legal_review_reference)) BETWEEN 8 AND 240),
  evidence_source text NOT NULL DEFAULT 'SHOPIFY_CUSTOMER_DEFAULT_ADDRESS'
    CHECK (evidence_source = 'SHOPIFY_CUSTOMER_DEFAULT_ADDRESS'),
  require_region boolean NOT NULL DEFAULT true,
  max_consent_evidence_age interval NOT NULL,
  max_contact_evidence_age interval NOT NULL,
  approved_at timestamptz,
  expires_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT pg_catalog.now(),
  updated_at timestamptz NOT NULL DEFAULT pg_catalog.now(),
  CONSTRAINT shopify_pixel_delivery_jurisdiction_policy_v2_age_bounds
    CHECK (
      max_consent_evidence_age > interval '0'
      AND max_consent_evidence_age <= interval '30 days'
      AND max_contact_evidence_age > interval '0'
      AND max_contact_evidence_age <= interval '15 minutes'
    ),
  CONSTRAINT shopify_pixel_delivery_jurisdiction_policy_v2_approval_pair
    CHECK (policy_status <> 'APPROVED' OR approved_at IS NOT NULL),
  CONSTRAINT shopify_pixel_delivery_jurisdiction_policy_v2_expiry
    CHECK (expires_at IS NULL OR approved_at IS NULL OR expires_at > approved_at),
  CONSTRAINT shopify_pixel_delivery_jurisdiction_policy_v2_region_format
    CHECK (region_code IS NULL OR region_code ~ '^[A-Z0-9-]{1,12}$')
);

CREATE UNIQUE INDEX IF NOT EXISTS shopify_pixel_delivery_jurisdiction_policy_v2_scope_uidx
  ON henvalt.shopify_pixel_delivery_jurisdiction_policy_v2
  (country_code, COALESCE(region_code,''));

CREATE INDEX IF NOT EXISTS shopify_pixel_delivery_jurisdiction_policy_v2_active_idx
  ON henvalt.shopify_pixel_delivery_jurisdiction_policy_v2(country_code,region_code)
  WHERE policy_status='APPROVED';

ALTER TABLE henvalt.shopify_pixel_delivery_jurisdiction_policy_v2 ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON henvalt.shopify_pixel_delivery_jurisdiction_policy_v2
  FROM PUBLIC,anon,authenticated,service_role;

COMMENT ON TABLE henvalt.shopify_pixel_delivery_jurisdiction_policy_v2 IS
  'Explicitly reviewed cart/browse email jurisdiction policy. No defaults or country allowlist are seeded; Shopify default-address evidence is not legal approval by itself.';

CREATE OR REPLACE FUNCTION henvalt.assess_shopify_pixel_delivery_eligibility_v2(
  p_opportunity_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v record;
  v_contact record;
  v_policy record;
BEGIN
  IF current_setting('request.jwt.claim.role',true) IS DISTINCT FROM 'service_role' THEN
    RAISE EXCEPTION 'service_role_required' USING ERRCODE='42501';
  END IF;
  IF p_opportunity_id IS NULL THEN
    RETURN jsonb_build_object('eligible',false,'code','OPPORTUNITY_REQUIRED',
      'delivery_authorized',false);
  END IF;

  SELECT
    o.id,o.tenant_id,o.shopify_connection_id,o.app_key,o.opportunity_type,
    o.status,o.customer_identity_id,o.pixel_candidate_id,
    c.candidate_type,c.status AS candidate_status,c.customer_identity_id AS candidate_customer_id,
    c.last_activity_at,c.eligible_after,
    sc.active AS connection_active,sc.app_key AS connection_app_key,
    sc.shop_domain,sc.access_token_expires_at,sc.reauth_required_at,sc.token_type,sc.scopes,
    ar.lifecycle_status AS app_status,t.status::text AS tenant_status
  INTO v
  FROM henvalt.shopify_recovery_opportunity_v2 o
  JOIN henvalt.shopify_pixel_recovery_candidate_v2 c
    ON c.id=o.pixel_candidate_id
   AND c.tenant_id=o.tenant_id
   AND c.shopify_connection_id=o.shopify_connection_id
  JOIN henvalt.shopify_connections sc
    ON sc.id=o.shopify_connection_id AND sc.tenant_id=o.tenant_id
  JOIN henvalt.shopify_app_registry ar ON ar.app_key=o.app_key
  JOIN henvalt.tenants t ON t.id=o.tenant_id
  WHERE o.id=p_opportunity_id;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('eligible',false,'code','EXACT_STORE_OPPORTUNITY_NOT_FOUND',
      'delivery_authorized',false);
  END IF;
  IF v.opportunity_type NOT IN ('ABANDONED_CART','BROWSE_ABANDONMENT')
     OR v.candidate_type IS DISTINCT FROM v.opportunity_type
     OR v.status<>'REVIEW_REQUIRED'
     OR v.candidate_status<>'PROMOTED' THEN
    RETURN jsonb_build_object('eligible',false,'code','PIXEL_OPPORTUNITY_NOT_REVIEWABLE',
      'delivery_authorized',false);
  END IF;
  IF v.customer_identity_id IS NULL
     OR v.candidate_customer_id IS DISTINCT FROM v.customer_identity_id THEN
    RETURN jsonb_build_object('eligible',false,'code','EXACT_STORE_CUSTOMER_IDENTITY_REQUIRED',
      'delivery_authorized',false);
  END IF;
  IF v.connection_active IS DISTINCT FROM true OR v.app_status<>'active'
     OR v.connection_app_key IS DISTINCT FROM v.app_key OR v.tenant_status<>'ACTIVE' THEN
    RETURN jsonb_build_object('eligible',false,'code','APP_STORE_OR_TENANT_INACTIVE',
      'delivery_authorized',false);
  END IF;
  IF v.shop_domain !~ '^[a-z0-9][a-z0-9-]*[.]myshopify[.]com$'
     OR v.token_type<>'offline_expiring' OR v.reauth_required_at IS NOT NULL
     OR v.access_token_expires_at IS NULL
     OR v.access_token_expires_at<=pg_catalog.now()+interval '2 minutes'
     OR NOT coalesce('read_customers'=ANY(v.scopes),false) THEN
    RETURN jsonb_build_object('eligible',false,'code','SHOPIFY_CUSTOMER_ACCESS_UNAVAILABLE',
      'delivery_authorized',false);
  END IF;
  IF v.eligible_after>pg_catalog.now() THEN
    RETURN jsonb_build_object('eligible',false,'code','RECOVERY_DELAY_NOT_ELAPSED',
      'delivery_authorized',false);
  END IF;

  SELECT contact_available,country_code,region_code,observed_at
    INTO v_contact
  FROM henvalt.shopify_customer_contact_evidence_current_v2
  WHERE tenant_id=v.tenant_id
    AND shopify_connection_id=v.shopify_connection_id
    AND customer_identity_id=v.customer_identity_id;
  IF NOT FOUND OR v_contact.contact_available IS DISTINCT FROM true
     OR v_contact.country_code IS NULL THEN
    RETURN jsonb_build_object('eligible',false,'code','FRESH_CONTACT_AND_LOCATION_EVIDENCE_REQUIRED',
      'delivery_authorized',false);
  END IF;

  SELECT * INTO v_policy
  FROM henvalt.shopify_pixel_delivery_jurisdiction_policy_v2 p
  WHERE p.country_code=v_contact.country_code
    AND (p.region_code IS NOT DISTINCT FROM v_contact.region_code
      OR (p.region_code IS NULL AND p.require_region IS FALSE))
    AND p.policy_status='APPROVED'
    AND p.approved_at IS NOT NULL
    AND (p.expires_at IS NULL OR p.expires_at>pg_catalog.now())
  ORDER BY (p.region_code IS NOT NULL) DESC,p.approved_at DESC
  LIMIT 1;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('eligible',false,'code','JURISDICTION_POLICY_NOT_APPROVED',
      'delivery_authorized',false);
  END IF;
  IF v_policy.require_region IS TRUE AND v_contact.region_code IS NULL THEN
    RETURN jsonb_build_object('eligible',false,'code','SUBNATIONAL_LOCATION_REQUIRED',
      'delivery_authorized',false);
  END IF;
  IF v_contact.observed_at<pg_catalog.now()-v_policy.max_contact_evidence_age THEN
    RETURN jsonb_build_object('eligible',false,'code','CONTACT_LOCATION_EVIDENCE_STALE',
      'delivery_authorized',false);
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM henvalt.shopify_customer_email_consent_v2 consent
    WHERE consent.tenant_id=v.tenant_id
      AND consent.shopify_connection_id=v.shopify_connection_id
      AND consent.customer_identity_id=v.customer_identity_id
      AND consent.marketing_state='SUBSCRIBED'
      AND consent.consent_updated_at IS NOT NULL
      AND consent.observed_at>=pg_catalog.now()-v_policy.max_consent_evidence_age
  ) THEN
    RETURN jsonb_build_object('eligible',false,'code','FRESH_SUBSCRIBED_MARKETING_CONSENT_REQUIRED',
      'delivery_authorized',false);
  END IF;
  IF EXISTS (
    SELECT 1 FROM henvalt.shopify_delivery_suppressions_v2 s
    WHERE s.tenant_id=v.tenant_id AND s.shopify_connection_id=v.shopify_connection_id
      AND s.customer_identity_id=v.customer_identity_id AND s.active IS TRUE
  ) THEN
    RETURN jsonb_build_object('eligible',false,'code','RECIPIENT_SUPPRESSED',
      'delivery_authorized',false);
  END IF;
  IF EXISTS (
    SELECT 1 FROM henvalt.shopify_customer_redaction_guards_v2 g
    WHERE g.tenant_id=v.tenant_id AND g.shopify_connection_id=v.shopify_connection_id
      AND g.customer_identity_id=v.customer_identity_id
      AND g.state IN ('ACTIVE','REVIEW_REQUIRED')
  ) THEN
    RETURN jsonb_build_object('eligible',false,'code','CUSTOMER_PRIVACY_GUARD_ACTIVE',
      'delivery_authorized',false);
  END IF;
  IF EXISTS (
    SELECT 1 FROM henvalt.shopify_order_identity_v2 o
    WHERE o.tenant_id=v.tenant_id AND o.shopify_connection_id=v.shopify_connection_id
      AND o.customer_identity_id=v.customer_identity_id
      AND o.ordered_at>=v.last_activity_at AND o.cancelled_at IS NULL
  ) THEN
    RETURN jsonb_build_object('eligible',false,'code','SAME_STORE_CUSTOMER_CONVERTED',
      'delivery_authorized',false);
  END IF;
  IF EXISTS (
    SELECT 1 FROM henvalt.shopify_recovery_intervention_v2 i
    WHERE i.opportunity_id=v.id
  ) THEN
    RETURN jsonb_build_object('eligible',false,'code','INTERVENTION_ALREADY_EXISTS',
      'delivery_authorized',false);
  END IF;
  IF NOT EXISTS (
    SELECT 1
    FROM henvalt.shopify_mailer_provider_registry_v2 pr
    JOIN henvalt.shopify_sender_profiles_v2 sp
      ON sp.tenant_id=pr.tenant_id
     AND sp.shopify_connection_id=v.shopify_connection_id
     AND sp.provider_account_key=pr.provider_account_key
    JOIN henvalt.billing_accounts ba ON ba.tenant_id=pr.tenant_id
    WHERE pr.tenant_id=v.tenant_id AND pr.status='ACTIVE'
      AND pr.email_unit_cost_amount IS NOT NULL AND pr.email_unit_cost_amount>0
      AND pr.email_unit_cost_currency=pg_catalog.upper(pg_catalog.btrim(ba.currency::text))
      AND sp.status='ACTIVE' AND sp.verified_at IS NOT NULL
      AND ba.status='ACTIVE' AND ba.test_mode IS FALSE
      AND ba.henvalt_percentage>0 AND ba.usage_cap_amount>0
      AND ba.monthly_email_limit>0
  ) THEN
    RETURN jsonb_build_object('eligible',false,'code','SENDER_PROVIDER_OR_BILLING_NOT_READY',
      'delivery_authorized',false);
  END IF;

  RETURN jsonb_build_object(
    'eligible',true,
    'code','ELIGIBLE_FOR_AUTHORIZATION_REVIEW',
    'opportunity_id',v.id,
    'policy_version',v_policy.policy_version,
    'policy_reference_present',true,
    'delivery_authorized',false,
    'permit_issued',false,
    'intervention_created',false,
    'send_attempt_created',false,
    'recipient_email_returned',false,
    'provider_cost_reserved',false
  );
END;
$function$;

REVOKE ALL ON FUNCTION henvalt.assess_shopify_pixel_delivery_eligibility_v2(uuid)
  FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION henvalt.assess_shopify_pixel_delivery_eligibility_v2(uuid)
  TO service_role;

COMMIT;

-- HENVALT fresh Shopify Admin API marketing-consent lookup evidence V2.
-- Append-only, exact-store, PII-free. This records observed consent state only;
-- it never authorizes delivery or stores an email/token/raw Shopify response.
BEGIN;

CREATE TABLE IF NOT EXISTS henvalt.shopify_customer_marketing_consent_lookup_evidence_v2 (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id uuid NOT NULL,
  shopify_connection_id uuid NOT NULL,
  customer_identity_id uuid NOT NULL,
  marketing_state text NOT NULL CHECK (marketing_state IN
    ('SUBSCRIBED','NOT_SUBSCRIBED','UNSUBSCRIBED','PENDING','INVALID','REDACTED','UNKNOWN')),
  consent_updated_at timestamptz,
  observed_at timestamptz NOT NULL,
  lookup_id uuid NOT NULL,
  evidence_source text NOT NULL DEFAULT 'SHOPIFY_ADMIN_CUSTOMER_QUERY'
    CHECK (evidence_source='SHOPIFY_ADMIN_CUSTOMER_QUERY'),
  created_at timestamptz NOT NULL DEFAULT pg_catalog.now(),
  CONSTRAINT shopify_customer_marketing_consent_lookup_identity_fk
    FOREIGN KEY (customer_identity_id,tenant_id,shopify_connection_id)
    REFERENCES henvalt.shopify_customer_identity_v2(id,tenant_id,shopify_connection_id)
    ON UPDATE RESTRICT ON DELETE RESTRICT,
  CONSTRAINT shopify_customer_marketing_consent_lookup_connection_fk
    FOREIGN KEY (shopify_connection_id,tenant_id)
    REFERENCES henvalt.shopify_connections(id,tenant_id)
    ON UPDATE RESTRICT ON DELETE RESTRICT,
  CONSTRAINT shopify_customer_marketing_consent_lookup_uidx
    UNIQUE (shopify_connection_id,lookup_id),
  CONSTRAINT shopify_customer_marketing_consent_lookup_scoped_uidx
    UNIQUE (id,tenant_id,shopify_connection_id,customer_identity_id)
);

CREATE TABLE IF NOT EXISTS henvalt.shopify_customer_marketing_consent_lookup_current_v2 (
  tenant_id uuid NOT NULL,
  shopify_connection_id uuid NOT NULL,
  customer_identity_id uuid NOT NULL,
  evidence_id uuid NOT NULL,
  marketing_state text NOT NULL CHECK (marketing_state IN
    ('SUBSCRIBED','NOT_SUBSCRIBED','UNSUBSCRIBED','PENDING','INVALID','REDACTED','UNKNOWN')),
  consent_updated_at timestamptz,
  observed_at timestamptz NOT NULL,
  updated_at timestamptz NOT NULL DEFAULT pg_catalog.now(),
  PRIMARY KEY (shopify_connection_id,customer_identity_id),
  FOREIGN KEY (customer_identity_id,tenant_id,shopify_connection_id)
    REFERENCES henvalt.shopify_customer_identity_v2(id,tenant_id,shopify_connection_id)
    ON UPDATE RESTRICT ON DELETE RESTRICT,
  FOREIGN KEY (evidence_id,tenant_id,shopify_connection_id,customer_identity_id)
    REFERENCES henvalt.shopify_customer_marketing_consent_lookup_evidence_v2(id,tenant_id,shopify_connection_id,customer_identity_id)
    ON UPDATE RESTRICT ON DELETE RESTRICT
);

CREATE INDEX IF NOT EXISTS shopify_customer_marketing_consent_lookup_fresh_idx
  ON henvalt.shopify_customer_marketing_consent_lookup_current_v2
  (shopify_connection_id,customer_identity_id,observed_at DESC);

ALTER TABLE henvalt.shopify_customer_marketing_consent_lookup_evidence_v2 ENABLE ROW LEVEL SECURITY;
ALTER TABLE henvalt.shopify_customer_marketing_consent_lookup_current_v2 ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON henvalt.shopify_customer_marketing_consent_lookup_evidence_v2
  FROM PUBLIC,anon,authenticated,service_role;
REVOKE ALL ON henvalt.shopify_customer_marketing_consent_lookup_current_v2
  FROM PUBLIC,anon,authenticated,service_role;

COMMENT ON TABLE henvalt.shopify_customer_marketing_consent_lookup_evidence_v2 IS
  'Append-only exact-store Shopify Admin API email marketing consent observations. No recipient email, token, address, or raw response.';
COMMENT ON TABLE henvalt.shopify_customer_marketing_consent_lookup_current_v2 IS
  'Latest Admin API consent observation. Must be freshly queried at delivery; a newer webhook event invalidates this observation until re-queried.';

CREATE OR REPLACE FUNCTION henvalt.record_shopify_customer_marketing_consent_lookup_v2(
  p_connection_id uuid,
  p_customer_identity_id uuid,
  p_marketing_state text,
  p_consent_updated_at timestamptz,
  p_observed_at timestamptz,
  p_lookup_id uuid
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=''
AS $function$
DECLARE
  v_connection record;
  v_evidence_id uuid;
  v_existing_at timestamptz;
  v_rows integer:=0;
  v_state text;
BEGIN
  IF current_setting('request.jwt.claim.role',true) IS DISTINCT FROM 'service_role' THEN
    RAISE EXCEPTION 'service_role_required' USING ERRCODE='42501';
  END IF;
  v_state:=upper(coalesce(nullif(btrim(p_marketing_state),''),'UNKNOWN'));
  IF v_state NOT IN ('SUBSCRIBED','NOT_SUBSCRIBED','UNSUBSCRIBED','PENDING','INVALID','REDACTED') THEN
    v_state:='UNKNOWN';
  END IF;
  IF p_connection_id IS NULL OR p_customer_identity_id IS NULL OR p_lookup_id IS NULL
     OR p_observed_at IS NULL
     OR p_observed_at<pg_catalog.now()-interval '5 minutes'
     OR p_observed_at>pg_catalog.now()+interval '1 minute'
     OR (p_consent_updated_at IS NOT NULL AND p_consent_updated_at>p_observed_at+interval '1 minute') THEN
    RETURN jsonb_build_object('accepted',false,'code','INVALID_EVIDENCE');
  END IF;

  SELECT sc.tenant_id,sc.active,ar.lifecycle_status,t.status::text AS tenant_status
    INTO v_connection
  FROM henvalt.shopify_connections sc
  JOIN henvalt.shopify_app_registry ar ON ar.app_key=sc.app_key
  JOIN henvalt.tenants t ON t.id=sc.tenant_id
  WHERE sc.id=p_connection_id
  FOR SHARE OF sc;
  IF NOT FOUND OR v_connection.active IS DISTINCT FROM true
     OR v_connection.tenant_status<>'ACTIVE' OR v_connection.lifecycle_status<>'active' THEN
    RETURN jsonb_build_object('accepted',false,'code','STORE_OR_APP_INACTIVE');
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM henvalt.shopify_customer_identity_v2 ci
    WHERE ci.id=p_customer_identity_id AND ci.tenant_id=v_connection.tenant_id
      AND ci.shopify_connection_id=p_connection_id
  ) THEN
    RETURN jsonb_build_object('accepted',false,'code','CUSTOMER_IDENTITY_SCOPE_MISMATCH');
  END IF;

  INSERT INTO henvalt.shopify_customer_marketing_consent_lookup_evidence_v2(
    tenant_id,shopify_connection_id,customer_identity_id,marketing_state,
    consent_updated_at,observed_at,lookup_id
  ) VALUES(v_connection.tenant_id,p_connection_id,p_customer_identity_id,v_state,
    p_consent_updated_at,p_observed_at,p_lookup_id)
  ON CONFLICT(shopify_connection_id,lookup_id) DO NOTHING
  RETURNING id INTO v_evidence_id;

  IF v_evidence_id IS NULL THEN
    SELECT id INTO v_evidence_id
    FROM henvalt.shopify_customer_marketing_consent_lookup_evidence_v2
    WHERE shopify_connection_id=p_connection_id AND lookup_id=p_lookup_id
      AND customer_identity_id=p_customer_identity_id AND marketing_state=v_state
      AND consent_updated_at IS NOT DISTINCT FROM p_consent_updated_at;
    IF v_evidence_id IS NULL THEN
      RETURN jsonb_build_object('accepted',false,'code','LOOKUP_ID_REPLAY_MISMATCH');
    END IF;
  END IF;

  SELECT observed_at INTO v_existing_at
  FROM henvalt.shopify_customer_marketing_consent_lookup_current_v2
  WHERE shopify_connection_id=p_connection_id AND customer_identity_id=p_customer_identity_id
  FOR UPDATE;
  IF NOT FOUND OR p_observed_at>v_existing_at THEN
    INSERT INTO henvalt.shopify_customer_marketing_consent_lookup_current_v2(
      tenant_id,shopify_connection_id,customer_identity_id,evidence_id,
      marketing_state,consent_updated_at,observed_at,updated_at
    ) VALUES(v_connection.tenant_id,p_connection_id,p_customer_identity_id,v_evidence_id,
      v_state,p_consent_updated_at,p_observed_at,pg_catalog.now())
    ON CONFLICT(shopify_connection_id,customer_identity_id) DO UPDATE
      SET evidence_id=EXCLUDED.evidence_id,marketing_state=EXCLUDED.marketing_state,
          consent_updated_at=EXCLUDED.consent_updated_at,observed_at=EXCLUDED.observed_at,
          updated_at=pg_catalog.now()
      WHERE EXCLUDED.observed_at>henvalt.shopify_customer_marketing_consent_lookup_current_v2.observed_at;
    GET DIAGNOSTICS v_rows=ROW_COUNT;
  END IF;
  RETURN jsonb_build_object('accepted',true,'evidence_id',v_evidence_id,
    'current_updated',v_rows>0,'recipient_pii_stored',false,'delivery_authorized',false);
END;
$function$;

REVOKE ALL ON FUNCTION henvalt.record_shopify_customer_marketing_consent_lookup_v2(uuid,uuid,text,timestamptz,timestamptz,uuid)
  FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION henvalt.record_shopify_customer_marketing_consent_lookup_v2(uuid,uuid,text,timestamptz,timestamptz,uuid)
  TO service_role;

-- Fresh Admin API observation is mandatory. Any later consent webhook invalidates
-- it, regardless of webhook state; the next trusted lookup must re-resolve state.
CREATE OR REPLACE FUNCTION henvalt.assess_shopify_pixel_delivery_eligibility_v2(
  p_opportunity_id uuid
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=''
AS $function$
DECLARE v record; v_contact record; v_policy record; v_consent record;
BEGIN
  IF current_setting('request.jwt.claim.role',true) IS DISTINCT FROM 'service_role' THEN
    RAISE EXCEPTION 'service_role_required' USING ERRCODE='42501';
  END IF;
  IF p_opportunity_id IS NULL THEN
    RETURN jsonb_build_object('eligible',false,'code','OPPORTUNITY_REQUIRED','delivery_authorized',false);
  END IF;
  SELECT o.id,o.tenant_id,o.shopify_connection_id,o.app_key,o.opportunity_type,o.status,
    o.customer_identity_id,o.pixel_candidate_id,c.candidate_type,c.status AS candidate_status,
    c.customer_identity_id AS candidate_customer_id,c.last_activity_at,c.eligible_after,
    sc.active AS connection_active,sc.app_key AS connection_app_key,sc.shop_domain,
    sc.access_token_expires_at,sc.reauth_required_at,sc.token_type,sc.scopes,
    ar.lifecycle_status AS app_status,t.status::text AS tenant_status
  INTO v
  FROM henvalt.shopify_recovery_opportunity_v2 o
  JOIN henvalt.shopify_pixel_recovery_candidate_v2 c ON c.id=o.pixel_candidate_id
    AND c.tenant_id=o.tenant_id AND c.shopify_connection_id=o.shopify_connection_id
  JOIN henvalt.shopify_connections sc ON sc.id=o.shopify_connection_id AND sc.tenant_id=o.tenant_id
  JOIN henvalt.shopify_app_registry ar ON ar.app_key=o.app_key
  JOIN henvalt.tenants t ON t.id=o.tenant_id
  WHERE o.id=p_opportunity_id;
  IF NOT FOUND THEN RETURN jsonb_build_object('eligible',false,'code','EXACT_STORE_OPPORTUNITY_NOT_FOUND','delivery_authorized',false); END IF;
  IF v.opportunity_type NOT IN ('ABANDONED_CART','BROWSE_ABANDONMENT')
    OR v.candidate_type IS DISTINCT FROM v.opportunity_type OR v.status<>'REVIEW_REQUIRED'
    OR v.candidate_status<>'PROMOTED' THEN
    RETURN jsonb_build_object('eligible',false,'code','PIXEL_OPPORTUNITY_NOT_REVIEWABLE','delivery_authorized',false);
  END IF;
  IF v.customer_identity_id IS NULL OR v.candidate_customer_id IS DISTINCT FROM v.customer_identity_id THEN
    RETURN jsonb_build_object('eligible',false,'code','EXACT_STORE_CUSTOMER_IDENTITY_REQUIRED','delivery_authorized',false);
  END IF;
  IF v.connection_active IS DISTINCT FROM true OR v.app_status<>'active'
    OR v.connection_app_key IS DISTINCT FROM v.app_key OR v.tenant_status<>'ACTIVE' THEN
    RETURN jsonb_build_object('eligible',false,'code','APP_STORE_OR_TENANT_INACTIVE','delivery_authorized',false);
  END IF;
  IF v.shop_domain !~ '^[a-z0-9][a-z0-9-]*[.]myshopify[.]com$'
    OR v.token_type<>'offline_expiring' OR v.reauth_required_at IS NOT NULL
    OR v.access_token_expires_at IS NULL OR v.access_token_expires_at<=pg_catalog.now()+interval '2 minutes'
    OR NOT coalesce('read_customers'=ANY(v.scopes),false) THEN
    RETURN jsonb_build_object('eligible',false,'code','SHOPIFY_CUSTOMER_ACCESS_UNAVAILABLE','delivery_authorized',false);
  END IF;
  IF v.eligible_after>pg_catalog.now() THEN
    RETURN jsonb_build_object('eligible',false,'code','RECOVERY_DELAY_NOT_ELAPSED','delivery_authorized',false);
  END IF;
  SELECT contact_available,country_code,region_code,observed_at INTO v_contact
  FROM henvalt.shopify_customer_contact_evidence_current_v2
  WHERE tenant_id=v.tenant_id AND shopify_connection_id=v.shopify_connection_id
    AND customer_identity_id=v.customer_identity_id;
  IF NOT FOUND OR v_contact.contact_available IS DISTINCT FROM true OR v_contact.country_code IS NULL THEN
    RETURN jsonb_build_object('eligible',false,'code','FRESH_CONTACT_AND_LOCATION_EVIDENCE_REQUIRED','delivery_authorized',false);
  END IF;
  SELECT * INTO v_policy FROM henvalt.shopify_pixel_delivery_jurisdiction_policy_v2 p
  WHERE p.country_code=v_contact.country_code
    AND (p.region_code IS NOT DISTINCT FROM v_contact.region_code OR (p.region_code IS NULL AND p.require_region IS FALSE))
    AND p.policy_status='APPROVED' AND p.approved_at IS NOT NULL
    AND (p.expires_at IS NULL OR p.expires_at>pg_catalog.now())
  ORDER BY (p.region_code IS NOT NULL) DESC,p.approved_at DESC LIMIT 1;
  IF NOT FOUND THEN RETURN jsonb_build_object('eligible',false,'code','JURISDICTION_POLICY_NOT_APPROVED','delivery_authorized',false); END IF;
  IF v_policy.require_region IS TRUE AND v_contact.region_code IS NULL THEN
    RETURN jsonb_build_object('eligible',false,'code','SUBNATIONAL_LOCATION_REQUIRED','delivery_authorized',false);
  END IF;
  IF v_contact.observed_at<pg_catalog.now()-v_policy.max_contact_evidence_age THEN
    RETURN jsonb_build_object('eligible',false,'code','CONTACT_LOCATION_EVIDENCE_STALE','delivery_authorized',false);
  END IF;

  SELECT * INTO v_consent
  FROM henvalt.shopify_customer_marketing_consent_lookup_current_v2
  WHERE tenant_id=v.tenant_id AND shopify_connection_id=v.shopify_connection_id
    AND customer_identity_id=v.customer_identity_id;
  IF NOT FOUND OR v_consent.marketing_state<>'SUBSCRIBED'
    OR v_consent.consent_updated_at IS NULL
    OR v_consent.observed_at<pg_catalog.now()-interval '5 minutes'
    OR v_consent.consent_updated_at>v_consent.observed_at+interval '1 minute' THEN
    RETURN jsonb_build_object('eligible',false,'code','FRESH_ADMIN_API_SUBSCRIBED_CONSENT_REQUIRED','delivery_authorized',false);
  END IF;
  IF EXISTS (
    SELECT 1 FROM henvalt.shopify_customer_email_consent_events_v2 e
    WHERE e.tenant_id=v.tenant_id AND e.shopify_connection_id=v.shopify_connection_id
      AND e.customer_identity_id=v.customer_identity_id AND e.received_at>v_consent.observed_at
  ) THEN
    RETURN jsonb_build_object('eligible',false,'code','CONSENT_WEBHOOK_AFTER_ADMIN_LOOKUP','delivery_authorized',false);
  END IF;
  IF EXISTS (SELECT 1 FROM henvalt.shopify_delivery_suppressions_v2 s
    WHERE s.tenant_id=v.tenant_id AND s.shopify_connection_id=v.shopify_connection_id
      AND s.customer_identity_id=v.customer_identity_id AND s.active IS TRUE) THEN
    RETURN jsonb_build_object('eligible',false,'code','RECIPIENT_SUPPRESSED','delivery_authorized',false);
  END IF;
  IF EXISTS (SELECT 1 FROM henvalt.shopify_customer_redaction_guards_v2 g
    WHERE g.tenant_id=v.tenant_id AND g.shopify_connection_id=v.shopify_connection_id
      AND g.customer_identity_id=v.customer_identity_id AND g.state IN ('ACTIVE','REVIEW_REQUIRED')) THEN
    RETURN jsonb_build_object('eligible',false,'code','CUSTOMER_PRIVACY_GUARD_ACTIVE','delivery_authorized',false);
  END IF;
  IF EXISTS (SELECT 1 FROM henvalt.shopify_order_identity_v2 o
    WHERE o.tenant_id=v.tenant_id AND o.shopify_connection_id=v.shopify_connection_id
      AND o.customer_identity_id=v.customer_identity_id AND o.ordered_at>=v.last_activity_at
      AND o.cancelled_at IS NULL) THEN
    RETURN jsonb_build_object('eligible',false,'code','SAME_STORE_CUSTOMER_CONVERTED','delivery_authorized',false);
  END IF;
  IF EXISTS (SELECT 1 FROM henvalt.shopify_recovery_intervention_v2 i WHERE i.opportunity_id=v.id) THEN
    RETURN jsonb_build_object('eligible',false,'code','INTERVENTION_ALREADY_EXISTS','delivery_authorized',false);
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM henvalt.shopify_mailer_provider_registry_v2 pr
    JOIN henvalt.shopify_sender_profiles_v2 sp ON sp.tenant_id=pr.tenant_id
      AND sp.shopify_connection_id=v.shopify_connection_id AND sp.provider_account_key=pr.provider_account_key
    JOIN henvalt.billing_accounts ba ON ba.tenant_id=pr.tenant_id
    WHERE pr.tenant_id=v.tenant_id AND pr.status='ACTIVE'
      AND pr.email_unit_cost_amount IS NOT NULL AND pr.email_unit_cost_amount>0
      AND pr.email_unit_cost_currency=pg_catalog.upper(pg_catalog.btrim(ba.currency::text))
      AND sp.status='ACTIVE' AND sp.verified_at IS NOT NULL AND ba.status='ACTIVE'
      AND ba.test_mode IS FALSE AND ba.henvalt_percentage>0 AND ba.usage_cap_amount>0
      AND ba.monthly_email_limit>0
  ) THEN
    RETURN jsonb_build_object('eligible',false,'code','SENDER_PROVIDER_OR_BILLING_NOT_READY','delivery_authorized',false);
  END IF;
  RETURN jsonb_build_object('eligible',true,'code','ELIGIBLE_FOR_AUTHORIZATION_REVIEW',
    'opportunity_id',v.id,'policy_version',v_policy.policy_version,
    'delivery_authorized',false,'permit_issued',false,'intervention_created',false,
    'send_attempt_created',false,'recipient_email_returned',false,'provider_cost_reserved',false);
END;
$function$;
REVOKE ALL ON FUNCTION henvalt.assess_shopify_pixel_delivery_eligibility_v2(uuid) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION henvalt.assess_shopify_pixel_delivery_eligibility_v2(uuid) TO service_role;
COMMIT;

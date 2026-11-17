-- HENVALT single-use exact-store delivery authorization V2.
-- PREPARATION ONLY. Depends on candidate migrations 001-016.
-- This migration creates a fail-closed authorization boundary; it does not
-- resolve shopper email, call MailerSend, or activate production delivery.

BEGIN;

CREATE TABLE IF NOT EXISTS henvalt.shopify_sender_profiles_v2 (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id uuid NOT NULL,
  shopify_connection_id uuid NOT NULL,
  provider_account_key text NOT NULL,
  from_email text NOT NULL,
  from_name text NOT NULL,
  status text NOT NULL DEFAULT 'PENDING'
    CHECK (status IN ('PENDING','ACTIVE','PAUSED','RETIRED')),
  verified_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT shopify_sender_profiles_v2_email_format
    CHECK (from_email ~* '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$'),
  CONSTRAINT shopify_sender_profiles_v2_name_nonempty
    CHECK (length(btrim(from_name)) BETWEEN 1 AND 120),
  CONSTRAINT shopify_sender_profiles_v2_connection_fkey
    FOREIGN KEY (shopify_connection_id,tenant_id)
    REFERENCES henvalt.shopify_connections(id,tenant_id)
    ON UPDATE RESTRICT ON DELETE RESTRICT,
  CONSTRAINT shopify_sender_profiles_v2_provider_fkey
    FOREIGN KEY (provider_account_key,tenant_id)
    REFERENCES henvalt.shopify_mailer_provider_registry_v2(provider_account_key,tenant_id)
    ON UPDATE RESTRICT ON DELETE RESTRICT,
  CONSTRAINT shopify_sender_profiles_v2_id_lineage_uidx
    UNIQUE (id,tenant_id,shopify_connection_id)
);

CREATE TABLE IF NOT EXISTS henvalt.shopify_delivery_permits_v2 (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id uuid NOT NULL,
  shopify_connection_id uuid NOT NULL,
  intervention_id uuid NOT NULL,
  customer_identity_id uuid NOT NULL,
  provider_account_key text NOT NULL,
  sender_profile_id uuid NOT NULL,
  permit_token_sha256 text NOT NULL UNIQUE
    CHECK (permit_token_sha256 ~ '^[0-9a-f]{64}$'),
  recipient_fingerprint bytea NOT NULL
    CHECK (pg_catalog.octet_length(recipient_fingerprint)=32),
  expires_at timestamptz NOT NULL,
  consumed_at timestamptz,
  send_attempt_id uuid,
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT shopify_delivery_permits_v2_connection_fkey
    FOREIGN KEY (shopify_connection_id,tenant_id)
    REFERENCES henvalt.shopify_connections(id,tenant_id)
    ON UPDATE RESTRICT ON DELETE RESTRICT,
  CONSTRAINT shopify_delivery_permits_v2_intervention_fkey
    FOREIGN KEY (intervention_id,tenant_id,shopify_connection_id,customer_identity_id)
    REFERENCES henvalt.shopify_recovery_intervention_v2(id,tenant_id,shopify_connection_id,customer_identity_id)
    ON UPDATE RESTRICT ON DELETE RESTRICT,
  CONSTRAINT shopify_delivery_permits_v2_sender_fkey
    FOREIGN KEY (sender_profile_id,tenant_id,shopify_connection_id)
    REFERENCES henvalt.shopify_sender_profiles_v2(id,tenant_id,shopify_connection_id)
    ON UPDATE RESTRICT ON DELETE RESTRICT,
  CONSTRAINT shopify_delivery_permits_v2_provider_fkey
    FOREIGN KEY (provider_account_key,tenant_id)
    REFERENCES henvalt.shopify_mailer_provider_registry_v2(provider_account_key,tenant_id)
    ON UPDATE RESTRICT ON DELETE RESTRICT,
  CONSTRAINT shopify_delivery_permits_v2_attempt_fkey
    FOREIGN KEY (send_attempt_id,tenant_id,shopify_connection_id)
    REFERENCES henvalt.shopify_recovery_send_attempt_v2(id,tenant_id,shopify_connection_id)
    ON UPDATE RESTRICT ON DELETE RESTRICT,
  CONSTRAINT shopify_delivery_permits_v2_id_lineage_uidx
    UNIQUE (id,tenant_id,shopify_connection_id)
);

CREATE INDEX IF NOT EXISTS shopify_delivery_permits_v2_pending_idx
  ON henvalt.shopify_delivery_permits_v2(expires_at)
  WHERE consumed_at IS NULL;

ALTER TABLE henvalt.shopify_sender_profiles_v2 ENABLE ROW LEVEL SECURITY;
ALTER TABLE henvalt.shopify_delivery_permits_v2 ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON henvalt.shopify_sender_profiles_v2 FROM PUBLIC,anon,authenticated,service_role;
REVOKE ALL ON henvalt.shopify_delivery_permits_v2 FROM PUBLIC,anon,authenticated,service_role;

COMMENT ON TABLE henvalt.shopify_sender_profiles_v2 IS
  'Exact-store verified sender identity. Legacy tenant-wide sending_identities are intentionally not reused by V2.';
COMMENT ON TABLE henvalt.shopify_delivery_permits_v2 IS
  'Short-lived, single-use delivery capability. Stores only a hash of the permit token and a keyed recipient fingerprint; never stores recipient email.';

CREATE OR REPLACE FUNCTION henvalt.issue_shopify_delivery_permit_v2(
  p_intervention_id uuid,
  p_provider_account_key text,
  p_sender_profile_id uuid,
  p_recipient_fingerprint_hex text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_row record;
  v_token text;
  v_permit_id uuid;
  v_idempotency_key text;
  v_monthly_sends bigint;
BEGIN
  IF p_intervention_id IS NULL OR p_sender_profile_id IS NULL
     OR p_provider_account_key IS NULL
     OR p_recipient_fingerprint_hex IS NULL
     OR p_recipient_fingerprint_hex !~ '^[0-9a-fA-F]{64}$' THEN
    RETURN jsonb_build_object('authorized',false,'code','INVALID_REQUEST');
  END IF;

  SELECT
    i.id AS intervention_id,i.tenant_id,i.shopify_connection_id,
    i.customer_identity_id,i.opportunity_id,i.step_number,i.status AS intervention_status,
    opp.status AS opportunity_status,opp.app_key,opp.candidate_id,opp.checkout_identity_id,
    opp.customer_identity_id AS opportunity_customer_id,
    c.state AS candidate_state,c.checkout_token,c.checkout_identity_id AS candidate_checkout_id,
    ch.checkout_status,ch.jurisdiction_country_code,ch.shopify_checkout_token,
    ch.customer_identity_id AS checkout_customer_id,
    ci.external_customer_reference,
    sc.active AS connection_active,sc.app_key AS connection_app_key,
    ar.lifecycle_status AS app_status,t.status::text AS tenant_status,
    consent.marketing_state,consent.consent_updated_at,
    pr.status AS provider_status,pr.tenant_id AS provider_tenant_id,
    sp.status AS sender_status,sp.verified_at,sp.from_email,sp.from_name,
    ba.status AS billing_status,ba.test_mode,ba.henvalt_percentage,
    ba.usage_cap_amount,ba.monthly_email_limit
  INTO v_row
  FROM henvalt.shopify_recovery_intervention_v2 i
  JOIN henvalt.shopify_recovery_opportunity_v2 opp
    ON opp.id=i.opportunity_id AND opp.tenant_id=i.tenant_id
   AND opp.shopify_connection_id=i.shopify_connection_id
  JOIN henvalt.shopify_checkout_recovery_candidate_v2 c
    ON c.id=opp.candidate_id AND c.tenant_id=i.tenant_id
   AND c.shopify_connection_id=i.shopify_connection_id
  JOIN henvalt.shopify_checkout_identity_v2 ch
    ON ch.id=opp.checkout_identity_id AND ch.tenant_id=i.tenant_id
   AND ch.shopify_connection_id=i.shopify_connection_id
  JOIN henvalt.shopify_customer_identity_v2 ci
    ON ci.id=i.customer_identity_id AND ci.tenant_id=i.tenant_id
   AND ci.shopify_connection_id=i.shopify_connection_id
  JOIN henvalt.shopify_connections sc
    ON sc.id=i.shopify_connection_id AND sc.tenant_id=i.tenant_id
  JOIN henvalt.shopify_app_registry ar ON ar.app_key=opp.app_key
  JOIN henvalt.tenants t ON t.id=i.tenant_id
  JOIN henvalt.shopify_customer_email_consent_v2 consent
    ON consent.customer_identity_id=i.customer_identity_id
   AND consent.tenant_id=i.tenant_id
   AND consent.shopify_connection_id=i.shopify_connection_id
  JOIN henvalt.shopify_mailer_provider_registry_v2 pr
    ON pr.provider_account_key=p_provider_account_key AND pr.tenant_id=i.tenant_id
  JOIN henvalt.shopify_sender_profiles_v2 sp
    ON sp.id=p_sender_profile_id AND sp.tenant_id=i.tenant_id
   AND sp.shopify_connection_id=i.shopify_connection_id
   AND sp.provider_account_key=p_provider_account_key
  JOIN henvalt.billing_accounts ba ON ba.tenant_id=i.tenant_id
  WHERE i.id=p_intervention_id
  FOR UPDATE OF i,opp,c,ch,sc,ar,t,consent,pr,sp,ba;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('authorized',false,'code','DELIVERY_CHAIN_INCOMPLETE');
  END IF;

  IF v_row.intervention_status<>'READY_FOR_AUTHORIZATION'
     OR v_row.opportunity_status<>'CONTACT_RESOLUTION_PENDING'
     OR v_row.candidate_state<>'READY_FOR_CONTACT_RESOLUTION'
     OR v_row.opportunity_customer_id IS DISTINCT FROM v_row.customer_identity_id
     OR v_row.checkout_customer_id IS DISTINCT FROM v_row.customer_identity_id
     OR v_row.candidate_checkout_id IS DISTINCT FROM v_row.checkout_identity_id THEN
    RETURN jsonb_build_object('authorized',false,'code','RECOVERY_CHAIN_NOT_ELIGIBLE');
  END IF;
  IF v_row.connection_active IS DISTINCT FROM true
     OR v_row.app_status<>'active'
     OR v_row.connection_app_key IS DISTINCT FROM v_row.app_key
     OR v_row.tenant_status<>'ACTIVE' THEN
    RETURN jsonb_build_object('authorized',false,'code','APP_STORE_OR_TENANT_INACTIVE');
  END IF;
  IF v_row.checkout_status<>'OPEN'
     OR v_row.shopify_checkout_token IS DISTINCT FROM v_row.checkout_token
     OR v_row.jurisdiction_country_code IS NULL
     OR v_row.jurisdiction_country_code NOT IN ('GB','US','CA','AU')
     OR v_row.checkout_customer_id IS NULL THEN
    RETURN jsonb_build_object('authorized',false,'code','CHECKOUT_OR_JURISDICTION_INELIGIBLE');
  END IF;
  IF EXISTS (
    SELECT 1 FROM henvalt.shopify_order_identity_v2 o
    WHERE o.tenant_id=v_row.tenant_id
      AND o.shopify_connection_id=v_row.shopify_connection_id
      AND o.checkout_token=v_row.checkout_token
  ) THEN
    RETURN jsonb_build_object('authorized',false,'code','SAME_STORE_ORDER_EXISTS');
  END IF;
  IF v_row.marketing_state<>'SUBSCRIBED' OR v_row.consent_updated_at IS NULL THEN
    RETURN jsonb_build_object('authorized',false,'code','CURRENT_EMAIL_CONSENT_REQUIRED');
  END IF;
  IF EXISTS (
    SELECT 1 FROM henvalt.shopify_delivery_suppressions_v2 s
    WHERE s.tenant_id=v_row.tenant_id
      AND s.shopify_connection_id=v_row.shopify_connection_id
      AND s.customer_identity_id=v_row.customer_identity_id
      AND s.active IS TRUE
  ) OR EXISTS (
    SELECT 1 FROM henvalt.shopify_delivery_suppressions_v2 s
    WHERE s.tenant_id=v_row.tenant_id
      AND s.shopify_connection_id=v_row.shopify_connection_id
      AND s.recipient_fingerprint=pg_catalog.decode(p_recipient_fingerprint_hex,'hex')
      AND s.active IS TRUE
  ) THEN
    RETURN jsonb_build_object('authorized',false,'code','RECIPIENT_SUPPRESSED');
  END IF;
  IF v_row.provider_status<>'ACTIVE'
     OR v_row.sender_status<>'ACTIVE'
     OR v_row.verified_at IS NULL
     OR v_row.from_email IS NULL
     OR v_row.billing_status<>'ACTIVE'
     OR v_row.test_mode IS DISTINCT FROM false
     OR v_row.henvalt_percentage IS NULL OR v_row.henvalt_percentage<=0
     OR v_row.usage_cap_amount IS NULL OR v_row.usage_cap_amount<=0
     OR v_row.monthly_email_limit IS NULL OR v_row.monthly_email_limit<=0 THEN
    RETURN jsonb_build_object('authorized',false,'code','BILLING_PROVIDER_OR_SENDER_NOT_READY');
  END IF;

  SELECT count(*) INTO v_monthly_sends
  FROM henvalt.shopify_recovery_send_attempt_v2 a
  WHERE a.tenant_id=v_row.tenant_id
    AND a.created_at>=date_trunc('month',pg_catalog.now());
  IF v_monthly_sends>=v_row.monthly_email_limit THEN
    RETURN jsonb_build_object('authorized',false,'code','MERCHANT_MONTHLY_EMAIL_CAP_REACHED');
  END IF;

  v_idempotency_key:='v2-intervention:'||v_row.intervention_id::text||':step:'||v_row.step_number::text;
  IF EXISTS (
    SELECT 1 FROM henvalt.shopify_recovery_send_attempt_v2 a
    WHERE a.shopify_connection_id=v_row.shopify_connection_id
      AND a.idempotency_key=v_idempotency_key
  ) THEN
    RETURN jsonb_build_object('authorized',false,'code','DELIVERY_ALREADY_CLAIMED');
  END IF;

  v_token:=pg_catalog.encode(extensions.gen_random_bytes(32),'hex');
  INSERT INTO henvalt.shopify_delivery_permits_v2(
    tenant_id,shopify_connection_id,intervention_id,customer_identity_id,
    provider_account_key,sender_profile_id,permit_token_sha256,
    recipient_fingerprint,expires_at
  ) VALUES (
    v_row.tenant_id,v_row.shopify_connection_id,v_row.intervention_id,
    v_row.customer_identity_id,p_provider_account_key,p_sender_profile_id,
    pg_catalog.encode(extensions.digest(pg_catalog.convert_to(v_token,'UTF8'),'sha256'),'hex'),
    pg_catalog.decode(p_recipient_fingerprint_hex,'hex'),
    pg_catalog.now()+interval '3 minutes'
  ) RETURNING id INTO v_permit_id;

  RETURN jsonb_build_object(
    'authorized',true,'permit_id',v_permit_id,'permit_token',v_token,
    'expires_in_seconds',180,'recipient_email_returned',false,
    'recipient_fingerprint_stored',true
  );
END;
$function$;

CREATE OR REPLACE FUNCTION henvalt.consume_shopify_delivery_permit_v2(p_permit_token text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_permit henvalt.shopify_delivery_permits_v2%ROWTYPE;
  v_row record;
  v_attempt_id uuid;
  v_idempotency_key text;
  v_monthly_sends bigint;
BEGIN
  IF p_permit_token IS NULL OR p_permit_token !~ '^[0-9a-f]{64}$' THEN
    RETURN jsonb_build_object('consumed',false,'code','INVALID_PERMIT');
  END IF;

  SELECT * INTO v_permit
  FROM henvalt.shopify_delivery_permits_v2
  WHERE permit_token_sha256=pg_catalog.encode(
    extensions.digest(pg_catalog.convert_to(p_permit_token,'UTF8'),'sha256'),'hex'
  )
  FOR UPDATE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('consumed',false,'code','PERMIT_NOT_FOUND');
  END IF;
  IF v_permit.consumed_at IS NOT NULL THEN
    RETURN jsonb_build_object('consumed',false,'code','PERMIT_ALREADY_USED');
  END IF;
  IF v_permit.expires_at<=pg_catalog.now() THEN
    RETURN jsonb_build_object('consumed',false,'code','PERMIT_EXPIRED');
  END IF;

  SELECT
    i.id AS intervention_id,i.tenant_id,i.shopify_connection_id,
    i.customer_identity_id,i.opportunity_id,i.step_number,i.status AS intervention_status,
    opp.status AS opportunity_status,opp.app_key,opp.candidate_id,opp.checkout_identity_id,
    c.state AS candidate_state,c.checkout_token,
    ch.checkout_status,ch.jurisdiction_country_code,ch.shopify_checkout_token,
    consent.marketing_state,consent.consent_updated_at,
    sc.active AS connection_active,sc.app_key AS connection_app_key,
    ar.lifecycle_status AS app_status,t.status::text AS tenant_status,
    pr.status AS provider_status,sp.status AS sender_status,sp.verified_at,
    ba.status AS billing_status,ba.test_mode,ba.henvalt_percentage,
    ba.usage_cap_amount,ba.monthly_email_limit,sp.from_email,sp.from_name
  INTO v_row
  FROM henvalt.shopify_recovery_intervention_v2 i
  JOIN henvalt.shopify_recovery_opportunity_v2 opp
    ON opp.id=i.opportunity_id AND opp.tenant_id=i.tenant_id
   AND opp.shopify_connection_id=i.shopify_connection_id
  JOIN henvalt.shopify_checkout_recovery_candidate_v2 c
    ON c.id=opp.candidate_id AND c.tenant_id=i.tenant_id
   AND c.shopify_connection_id=i.shopify_connection_id
  JOIN henvalt.shopify_checkout_identity_v2 ch
    ON ch.id=opp.checkout_identity_id AND ch.tenant_id=i.tenant_id
   AND ch.shopify_connection_id=i.shopify_connection_id
  JOIN henvalt.shopify_customer_email_consent_v2 consent
    ON consent.customer_identity_id=i.customer_identity_id
   AND consent.tenant_id=i.tenant_id
   AND consent.shopify_connection_id=i.shopify_connection_id
  JOIN henvalt.shopify_connections sc
    ON sc.id=i.shopify_connection_id AND sc.tenant_id=i.tenant_id
  JOIN henvalt.shopify_app_registry ar ON ar.app_key=opp.app_key
  JOIN henvalt.tenants t ON t.id=i.tenant_id
  JOIN henvalt.shopify_mailer_provider_registry_v2 pr
    ON pr.provider_account_key=v_permit.provider_account_key AND pr.tenant_id=i.tenant_id
  JOIN henvalt.shopify_sender_profiles_v2 sp
    ON sp.id=v_permit.sender_profile_id AND sp.tenant_id=i.tenant_id
   AND sp.shopify_connection_id=i.shopify_connection_id
   AND sp.provider_account_key=v_permit.provider_account_key
  JOIN henvalt.billing_accounts ba ON ba.tenant_id=i.tenant_id
  WHERE i.id=v_permit.intervention_id
    AND i.tenant_id=v_permit.tenant_id
    AND i.shopify_connection_id=v_permit.shopify_connection_id
    AND i.customer_identity_id=v_permit.customer_identity_id
  FOR UPDATE OF i,opp,c,ch,consent,sc,ar,t,pr,sp,ba;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('consumed',false,'code','DELIVERY_CHAIN_INCOMPLETE');
  END IF;
  IF v_row.intervention_status<>'READY_FOR_AUTHORIZATION'
     OR v_row.opportunity_status<>'CONTACT_RESOLUTION_PENDING'
     OR v_row.candidate_state<>'READY_FOR_CONTACT_RESOLUTION'
     OR v_row.connection_active IS DISTINCT FROM true
     OR v_row.app_status<>'active'
     OR v_row.connection_app_key IS DISTINCT FROM v_row.app_key
     OR v_row.tenant_status<>'ACTIVE'
     OR v_row.checkout_status<>'OPEN'
     OR v_row.jurisdiction_country_code NOT IN ('GB','US','CA','AU')
     OR v_row.shopify_checkout_token IS DISTINCT FROM v_row.checkout_token
     OR v_row.marketing_state<>'SUBSCRIBED'
     OR v_row.consent_updated_at IS NULL
     OR v_row.provider_status<>'ACTIVE'
     OR v_row.sender_status<>'ACTIVE'
     OR v_row.verified_at IS NULL
     OR v_row.billing_status<>'ACTIVE'
     OR v_row.test_mode IS DISTINCT FROM false
     OR v_row.henvalt_percentage IS NULL OR v_row.henvalt_percentage<=0
     OR v_row.usage_cap_amount IS NULL OR v_row.usage_cap_amount<=0
     OR v_row.monthly_email_limit IS NULL OR v_row.monthly_email_limit<=0 THEN
    RETURN jsonb_build_object('consumed',false,'code','DELIVERY_GATE_CHANGED');
  END IF;
  IF EXISTS (
    SELECT 1 FROM henvalt.shopify_order_identity_v2 o
    WHERE o.tenant_id=v_permit.tenant_id
      AND o.shopify_connection_id=v_permit.shopify_connection_id
      AND o.checkout_token=v_row.checkout_token
  ) OR EXISTS (
    SELECT 1 FROM henvalt.shopify_delivery_suppressions_v2 s
    WHERE s.tenant_id=v_permit.tenant_id
      AND s.shopify_connection_id=v_permit.shopify_connection_id
      AND s.customer_identity_id=v_permit.customer_identity_id
      AND s.active IS TRUE
  ) OR EXISTS (
    SELECT 1 FROM henvalt.shopify_delivery_suppressions_v2 s
    WHERE s.tenant_id=v_permit.tenant_id
      AND s.shopify_connection_id=v_permit.shopify_connection_id
      AND s.recipient_fingerprint=v_permit.recipient_fingerprint
      AND s.active IS TRUE
  ) THEN
    RETURN jsonb_build_object('consumed',false,'code','ORDER_OR_SUPPRESSION_GATE_CHANGED');
  END IF;

  SELECT count(*) INTO v_monthly_sends
  FROM henvalt.shopify_recovery_send_attempt_v2 a
  WHERE a.tenant_id=v_permit.tenant_id
    AND a.created_at>=date_trunc('month',pg_catalog.now());
  IF v_monthly_sends>=v_row.monthly_email_limit THEN
    RETURN jsonb_build_object('consumed',false,'code','MERCHANT_MONTHLY_EMAIL_CAP_REACHED');
  END IF;

  v_idempotency_key:='v2-intervention:'||v_row.intervention_id::text||':step:'||v_row.step_number::text;
  INSERT INTO henvalt.shopify_recovery_send_attempt_v2(
    tenant_id,shopify_connection_id,customer_identity_id,intervention_id,
    provider_account_key,idempotency_key,status
  ) VALUES (
    v_permit.tenant_id,v_permit.shopify_connection_id,v_permit.customer_identity_id,
    v_permit.intervention_id,v_permit.provider_account_key,v_idempotency_key,'AUTHORIZED'
  )
  ON CONFLICT(shopify_connection_id,idempotency_key) DO NOTHING
  RETURNING id INTO v_attempt_id;

  IF v_attempt_id IS NULL THEN
    RETURN jsonb_build_object('consumed',false,'code','DELIVERY_ALREADY_CLAIMED');
  END IF;

  UPDATE henvalt.shopify_delivery_permits_v2
     SET consumed_at=pg_catalog.now(),send_attempt_id=v_attempt_id
   WHERE id=v_permit.id AND consumed_at IS NULL;
  UPDATE henvalt.shopify_recovery_intervention_v2
     SET status='AUTHORIZED',updated_at=pg_catalog.now()
   WHERE id=v_permit.intervention_id AND status='READY_FOR_AUTHORIZATION';

  RETURN jsonb_build_object(
    'consumed',true,'send_attempt_id',v_attempt_id,
    'provider_account_key',v_permit.provider_account_key,
    'sender_email',v_row.from_email,'sender_name',v_row.from_name,
    'recipient_email_returned',false,'idempotent',true
  );
END;
$function$;

REVOKE ALL ON FUNCTION henvalt.issue_shopify_delivery_permit_v2(uuid,text,uuid,text)
  FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION henvalt.consume_shopify_delivery_permit_v2(text)
  FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION henvalt.issue_shopify_delivery_permit_v2(uuid,text,uuid,text)
  TO service_role;
GRANT EXECUTE ON FUNCTION henvalt.consume_shopify_delivery_permit_v2(text)
  TO service_role;

COMMIT;

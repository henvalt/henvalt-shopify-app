-- HENVALT exact-store trusted Shopify customer contact/country evidence V2.
-- PREPARATION ONLY. A trusted server-side Admin API resolver must call this
-- service-role-only RPC after querying the exact connection's customer GID.
-- No email, address, phone, token, or raw Shopify response is persisted.
BEGIN;

CREATE TABLE IF NOT EXISTS henvalt.shopify_customer_contact_evidence_v2 (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id uuid NOT NULL,
  shopify_connection_id uuid NOT NULL,
  customer_identity_id uuid NOT NULL,
  contact_available boolean NOT NULL,
  country_code text,
  evidence_source text NOT NULL DEFAULT 'SHOPIFY_ADMIN_CUSTOMER_QUERY'
    CHECK (evidence_source = 'SHOPIFY_ADMIN_CUSTOMER_QUERY'),
  observed_at timestamptz NOT NULL,
  lookup_id uuid NOT NULL,
  created_at timestamptz NOT NULL DEFAULT pg_catalog.now(),
  CONSTRAINT shopify_customer_contact_evidence_v2_country_format
    CHECK (country_code IS NULL OR country_code ~ '^[A-Z]{2}$'),
  CONSTRAINT shopify_customer_contact_evidence_v2_identity_fkey
    FOREIGN KEY (customer_identity_id,tenant_id,shopify_connection_id)
    REFERENCES henvalt.shopify_customer_identity_v2(id,tenant_id,shopify_connection_id)
    ON UPDATE RESTRICT ON DELETE RESTRICT,
  CONSTRAINT shopify_customer_contact_evidence_v2_connection_fkey
    FOREIGN KEY (shopify_connection_id,tenant_id)
    REFERENCES henvalt.shopify_connections(id,tenant_id)
    ON UPDATE RESTRICT ON DELETE RESTRICT,
  CONSTRAINT shopify_customer_contact_evidence_v2_lookup_uidx
    UNIQUE (shopify_connection_id,lookup_id)
);

CREATE TABLE IF NOT EXISTS henvalt.shopify_customer_contact_evidence_current_v2 (
  tenant_id uuid NOT NULL,
  shopify_connection_id uuid NOT NULL,
  customer_identity_id uuid NOT NULL,
  evidence_id uuid NOT NULL,
  contact_available boolean NOT NULL,
  country_code text,
  observed_at timestamptz NOT NULL,
  updated_at timestamptz NOT NULL DEFAULT pg_catalog.now(),
  PRIMARY KEY (shopify_connection_id,customer_identity_id),
  CONSTRAINT shopify_customer_contact_evidence_current_v2_country_format
    CHECK (country_code IS NULL OR country_code ~ '^[A-Z]{2}$'),
  CONSTRAINT shopify_customer_contact_evidence_current_v2_identity_fkey
    FOREIGN KEY (customer_identity_id,tenant_id,shopify_connection_id)
    REFERENCES henvalt.shopify_customer_identity_v2(id,tenant_id,shopify_connection_id)
    ON UPDATE RESTRICT ON DELETE RESTRICT,
  CONSTRAINT shopify_customer_contact_evidence_current_v2_evidence_fkey
    FOREIGN KEY (evidence_id)
    REFERENCES henvalt.shopify_customer_contact_evidence_v2(id)
    ON UPDATE RESTRICT ON DELETE RESTRICT
);

CREATE INDEX IF NOT EXISTS shopify_customer_contact_evidence_current_v2_fresh_idx
  ON henvalt.shopify_customer_contact_evidence_current_v2
  (shopify_connection_id,customer_identity_id,observed_at DESC);

ALTER TABLE henvalt.shopify_customer_contact_evidence_v2 ENABLE ROW LEVEL SECURITY;
ALTER TABLE henvalt.shopify_customer_contact_evidence_current_v2 ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON henvalt.shopify_customer_contact_evidence_v2
  FROM PUBLIC,anon,authenticated,service_role;
REVOKE ALL ON henvalt.shopify_customer_contact_evidence_current_v2
  FROM PUBLIC,anon,authenticated,service_role;

COMMENT ON TABLE henvalt.shopify_customer_contact_evidence_v2 IS
  'Append-only exact-store evidence that a trusted Admin API lookup found a usable contact and optional country. Stores no contact value or address.';
COMMENT ON TABLE henvalt.shopify_customer_contact_evidence_current_v2 IS
  'Latest exact-store contact-availability and country evidence. Not a send authorization; evidence expires after 15 minutes and email must be re-resolved transiently at send time.';

CREATE OR REPLACE FUNCTION henvalt.record_shopify_customer_contact_evidence_v2(
  p_connection_id uuid,
  p_customer_identity_id uuid,
  p_contact_available boolean,
  p_country_code text,
  p_observed_at timestamptz,
  p_lookup_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_connection record;
  v_evidence_id uuid;
  v_existing_at timestamptz;\n  v_current_updated boolean := false;
BEGIN
  IF p_connection_id IS NULL OR p_customer_identity_id IS NULL
     OR p_contact_available IS NULL OR p_observed_at IS NULL
     OR p_lookup_id IS NULL
     OR (p_country_code IS NOT NULL AND upper(p_country_code) !~ '^[A-Z]{2}$')
     OR p_observed_at < pg_catalog.now()-interval '5 minutes'
     OR p_observed_at > pg_catalog.now()+interval '1 minute' THEN
    RETURN jsonb_build_object('accepted',false,'code','INVALID_EVIDENCE');
  END IF;

  SELECT sc.tenant_id,sc.active,sc.app_key,ar.lifecycle_status,t.status::text AS tenant_status
    INTO v_connection
  FROM henvalt.shopify_connections sc
  JOIN henvalt.shopify_app_registry ar ON ar.app_key=sc.app_key
  JOIN henvalt.tenants t ON t.id=sc.tenant_id
  WHERE sc.id=p_connection_id
  FOR SHARE OF sc;

  IF NOT FOUND OR v_connection.active IS DISTINCT FROM true
     OR v_connection.lifecycle_status IS NOT NULL
     OR v_connection.lifecycle_status IS NULL
     OR v_connection.tenant_status<>'ACTIVE'
     OR v_connection.lifecycle_status<>'active' THEN
    RETURN jsonb_build_object('accepted',false,'code','STORE_OR_APP_INACTIVE');
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM henvalt.shopify_customer_identity_v2 ci
    WHERE ci.id=p_customer_identity_id
      AND ci.tenant_id=v_connection.tenant_id
      AND ci.shopify_connection_id=p_connection_id
  ) THEN
    RETURN jsonb_build_object('accepted',false,'code','CUSTOMER_IDENTITY_SCOPE_MISMATCH');
  END IF;

  INSERT INTO henvalt.shopify_customer_contact_evidence_v2(
    tenant_id,shopify_connection_id,customer_identity_id,
    contact_available,country_code,observed_at,lookup_id
  ) VALUES (
    v_connection.tenant_id,p_connection_id,p_customer_identity_id,
    p_contact_available,CASE WHEN p_country_code IS NULL THEN NULL ELSE upper(p_country_code) END,
    p_observed_at,p_lookup_id
  )
  ON CONFLICT(shopify_connection_id,lookup_id) DO NOTHING
  RETURNING id INTO v_evidence_id;

  IF v_evidence_id IS NULL THEN
    SELECT e.id INTO v_evidence_id
    FROM henvalt.shopify_customer_contact_evidence_v2 e
    WHERE e.shopify_connection_id=p_connection_id AND e.lookup_id=p_lookup_id
      AND e.customer_identity_id=p_customer_identity_id
      AND e.contact_available=p_contact_available
      AND e.country_code IS NOT DISTINCT FROM CASE WHEN p_country_code IS NULL THEN NULL ELSE upper(p_country_code) END;
    IF v_evidence_id IS NULL THEN
      RETURN jsonb_build_object('accepted',false,'code','LOOKUP_ID_REPLAY_MISMATCH');
    END IF;
  END IF;

  SELECT observed_at INTO v_existing_at
  FROM henvalt.shopify_customer_contact_evidence_current_v2
  WHERE shopify_connection_id=p_connection_id
    AND customer_identity_id=p_customer_identity_id
  FOR UPDATE;

  IF NOT FOUND OR p_observed_at>v_existing_at THEN
    INSERT INTO henvalt.shopify_customer_contact_evidence_current_v2(
      tenant_id,shopify_connection_id,customer_identity_id,evidence_id,
      contact_available,country_code,observed_at,updated_at
    ) VALUES (
      v_connection.tenant_id,p_connection_id,p_customer_identity_id,v_evidence_id,
      p_contact_available,CASE WHEN p_country_code IS NULL THEN NULL ELSE upper(p_country_code) END,
      p_observed_at,pg_catalog.now()
    )
    ON CONFLICT(shopify_connection_id,customer_identity_id) DO UPDATE
      SET evidence_id=EXCLUDED.evidence_id,
          contact_available=EXCLUDED.contact_available,
          country_code=EXCLUDED.country_code,
          observed_at=EXCLUDED.observed_at,
          updated_at=pg_catalog.now();
  END IF;

  RETURN jsonb_build_object(
    'accepted',true,'evidence_id',v_evidence_id,
    'current_updated',v_current_updated,
    'contact_value_stored',false,'address_fields_stored',false,
    'send_authorized',false,'freshness_seconds',900
  );
END;
$function$;

REVOKE ALL ON FUNCTION henvalt.record_shopify_customer_contact_evidence_v2(uuid,uuid,boolean,text,timestamptz,uuid)
  FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION henvalt.record_shopify_customer_contact_evidence_v2(uuid,uuid,boolean,text,timestamptz,uuid)
  TO service_role;

COMMIT;

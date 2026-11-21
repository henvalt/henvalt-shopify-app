-- HENVALT exact-store Shopify email-marketing consent evidence V2.
-- PREPARATION ONLY. Depends on V2 app registry, verified webhook inbox,
-- exact-store customer identity and checkout identity migrations.
-- Stores pseudonymous customer references and consent evidence only: no email,
-- raw webhook body, address, phone, or inferred consent.

BEGIN;

CREATE TABLE IF NOT EXISTS henvalt.shopify_customer_email_consent_v2 (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id uuid NOT NULL,
  shopify_connection_id uuid NOT NULL,
  customer_identity_id uuid NOT NULL,
  marketing_state text NOT NULL
    CHECK (marketing_state IN ('SUBSCRIBED','NOT_SUBSCRIBED','UNSUBSCRIBED','PENDING','INVALID','REDACTED','UNKNOWN')),
  opt_in_level text,
  consent_updated_at timestamptz,
  observed_at timestamptz NOT NULL DEFAULT now(),
  source_delivery_id uuid NOT NULL,
  CONSTRAINT shopify_customer_email_consent_v2_identity_fkey
    FOREIGN KEY (customer_identity_id, tenant_id, shopify_connection_id)
    REFERENCES henvalt.shopify_customer_identity_v2(id, tenant_id, shopify_connection_id)
    ON UPDATE RESTRICT ON DELETE RESTRICT,
  CONSTRAINT shopify_customer_email_consent_v2_connection_fkey
    FOREIGN KEY (shopify_connection_id, tenant_id)
    REFERENCES henvalt.shopify_connections(id, tenant_id)
    ON UPDATE RESTRICT ON DELETE RESTRICT,
  CONSTRAINT shopify_customer_email_consent_v2_source_fkey
    FOREIGN KEY (source_delivery_id, tenant_id, shopify_connection_id)
    REFERENCES henvalt.shopify_webhook_deliveries(id, tenant_id, connection_id)
    ON UPDATE RESTRICT ON DELETE RESTRICT,
  CONSTRAINT shopify_customer_email_consent_v2_customer_uidx
    UNIQUE (shopify_connection_id, customer_identity_id)
);

CREATE TABLE IF NOT EXISTS henvalt.shopify_customer_email_consent_events_v2 (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id uuid NOT NULL,
  shopify_connection_id uuid NOT NULL,
  customer_identity_id uuid NOT NULL,
  source_delivery_id uuid NOT NULL,
  marketing_state text NOT NULL
    CHECK (marketing_state IN ('SUBSCRIBED','NOT_SUBSCRIBED','UNSUBSCRIBED','PENDING','INVALID','REDACTED','UNKNOWN')),
  opt_in_level text,
  consent_updated_at timestamptz,
  received_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT shopify_customer_email_consent_events_v2_identity_fkey
    FOREIGN KEY (customer_identity_id, tenant_id, shopify_connection_id)
    REFERENCES henvalt.shopify_customer_identity_v2(id, tenant_id, shopify_connection_id)
    ON UPDATE RESTRICT ON DELETE RESTRICT,
  CONSTRAINT shopify_customer_email_consent_events_v2_source_fkey
    FOREIGN KEY (source_delivery_id, tenant_id, shopify_connection_id)
    REFERENCES henvalt.shopify_webhook_deliveries(id, tenant_id, connection_id)
    ON UPDATE RESTRICT ON DELETE RESTRICT,
  CONSTRAINT shopify_customer_email_consent_events_v2_delivery_uidx
    UNIQUE (shopify_connection_id, source_delivery_id)
);

ALTER TABLE henvalt.shopify_checkout_identity_v2
  ADD COLUMN IF NOT EXISTS jurisdiction_country_code text;
ALTER TABLE henvalt.shopify_checkout_identity_v2
  ADD CONSTRAINT shopify_checkout_identity_v2_jurisdiction_country_format
  CHECK (jurisdiction_country_code IS NULL OR jurisdiction_country_code ~ '^[A-Z]{2}$');

CREATE INDEX IF NOT EXISTS shopify_customer_email_consent_v2_send_gate_idx
  ON henvalt.shopify_customer_email_consent_v2(shopify_connection_id, marketing_state, observed_at DESC);
CREATE INDEX IF NOT EXISTS shopify_customer_email_consent_events_v2_customer_idx
  ON henvalt.shopify_customer_email_consent_events_v2(shopify_connection_id, customer_identity_id, received_at DESC);

ALTER TABLE henvalt.shopify_customer_email_consent_v2 ENABLE ROW LEVEL SECURITY;
ALTER TABLE henvalt.shopify_customer_email_consent_events_v2 ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON henvalt.shopify_customer_email_consent_v2 FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON henvalt.shopify_customer_email_consent_events_v2 FROM PUBLIC, anon, authenticated, service_role;

COMMENT ON TABLE henvalt.shopify_customer_email_consent_v2 IS
  'Current exact-store Shopify email marketing consent. SUBSCRIBED is necessary but not sufficient for delivery; jurisdiction, contact, suppression and entitlement must also pass.';
COMMENT ON TABLE henvalt.shopify_customer_email_consent_events_v2 IS
  'Append-only, exact-store consent evidence keyed by verified webhook receipt; no email or raw payload.';
COMMENT ON COLUMN henvalt.shopify_checkout_identity_v2.jurisdiction_country_code IS
  'Country code observed on checkout shipping/billing address. NULL means unknown and must fail closed for jurisdiction-sensitive delivery.';

CREATE OR REPLACE FUNCTION henvalt.project_verified_shopify_email_consent_v2(
  p_route_token text,
  p_delivery_id text,
  p_raw_body_base64 text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_route record;
  v_body bytea;
  v_payload jsonb;
  v_digest text;
  v_customer_ref text;
  v_state text;
  v_opt_in text;
  v_consent_at timestamptz;
  v_customer_id uuid;
  v_existing_at timestamptz;
  v_existing_state text;
  v_existing_observed_at timestamptz;
  v_event_inserted integer;
BEGIN
  IF p_route_token IS NULL OR length(p_route_token) < 40 OR length(p_route_token) > 128
     OR p_delivery_id IS NULL OR length(btrim(p_delivery_id)) = 0
     OR p_raw_body_base64 IS NULL OR length(p_raw_body_base64) > 2800000 THEN
    RETURN jsonb_build_object('accepted',false,'code','INVALID_REQUEST');
  END IF;

  BEGIN
    v_body := pg_catalog.decode(p_raw_body_base64,'base64');
    v_payload := pg_catalog.convert_from(v_body,'UTF8')::jsonb;
  EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('accepted',false,'code','INVALID_BODY');
  END;
  IF pg_catalog.octet_length(v_body)=0 OR pg_catalog.octet_length(v_body)>2097152 THEN
    RETURN jsonb_build_object('accepted',false,'code','INVALID_BODY_SIZE');
  END IF;

  SELECT rt.tenant_id, rt.connection_id, rt.app_key,
         sc.active AS connection_active, ar.lifecycle_status AS app_status,
         d.id AS receipt_id, d.topic, d.raw_body_sha256, d.received_at
    INTO v_route
  FROM henvalt.shopify_webhook_route_tokens rt
  JOIN henvalt.shopify_connections sc
    ON sc.id=rt.connection_id AND sc.tenant_id=rt.tenant_id AND sc.app_key=rt.app_key
  JOIN henvalt.shopify_app_registry ar ON ar.app_key=rt.app_key
  JOIN henvalt.shopify_webhook_deliveries d
    ON d.connection_id=rt.connection_id AND d.tenant_id=rt.tenant_id AND d.app_key=rt.app_key
  WHERE rt.token_hash=pg_catalog.encode(extensions.digest(pg_catalog.convert_to(p_route_token,'UTF8'),'sha256'),'hex')
    AND rt.revoked_at IS NULL
    AND (rt.expires_at IS NULL OR rt.expires_at>pg_catalog.now())
    AND d.shopify_delivery_id=p_delivery_id
  FOR UPDATE OF d;

  IF NOT FOUND THEN RETURN jsonb_build_object('accepted',false,'code','VERIFIED_RECEIPT_NOT_FOUND'); END IF;
  IF v_route.topic <> 'customers_email_marketing_consent/update' THEN
    RETURN jsonb_build_object('accepted',false,'code','UNSUPPORTED_CONSENT_TOPIC');
  END IF;
  IF v_route.connection_active IS DISTINCT FROM true OR v_route.app_status <> 'active' THEN
    RETURN jsonb_build_object('accepted',false,'code','APP_OR_CONNECTION_INACTIVE');
  END IF;

  v_digest:=pg_catalog.encode(extensions.digest(v_body,'sha256'),'hex');
  IF v_digest IS DISTINCT FROM v_route.raw_body_sha256 THEN
    RETURN jsonb_build_object('accepted',false,'code','RECEIPT_BODY_MISMATCH');
  END IF;

  v_customer_ref:=NULLIF(pg_catalog.btrim(v_payload->>'customer_id'),'');
  IF v_customer_ref IS NULL OR length(v_customer_ref)>200 THEN
    RETURN jsonb_build_object('accepted',false,'code','CUSTOMER_REFERENCE_MISSING');
  END IF;

  v_state:=upper(COALESCE(NULLIF(v_payload->'email_marketing_consent'->>'state',''),'UNKNOWN'));
  IF v_state NOT IN ('SUBSCRIBED','NOT_SUBSCRIBED','UNSUBSCRIBED','PENDING','INVALID','REDACTED') THEN
    v_state:='UNKNOWN';
  END IF;
  v_opt_in:=upper(NULLIF(v_payload->'email_marketing_consent'->>'opt_in_level',''));
  BEGIN
    v_consent_at:=NULLIF(v_payload->'email_marketing_consent'->>'consent_updated_at','')::timestamptz;
  EXCEPTION WHEN OTHERS THEN
    v_consent_at:=NULL;
  END;

  INSERT INTO henvalt.shopify_customer_identity_v2(tenant_id,shopify_connection_id,external_customer_reference)
  VALUES(v_route.tenant_id,v_route.connection_id,v_customer_ref)
  ON CONFLICT(shopify_connection_id,external_customer_reference)
  DO UPDATE SET last_seen_at=GREATEST(henvalt.shopify_customer_identity_v2.last_seen_at,pg_catalog.now())
  RETURNING id INTO v_customer_id;

  INSERT INTO henvalt.shopify_customer_email_consent_events_v2(
    tenant_id,shopify_connection_id,customer_identity_id,source_delivery_id,
    marketing_state,opt_in_level,consent_updated_at,received_at
  )
  VALUES(v_route.tenant_id,v_route.connection_id,v_customer_id,v_route.receipt_id,
         v_state,v_opt_in,v_consent_at,v_route.received_at)
  ON CONFLICT(shopify_connection_id,source_delivery_id) DO NOTHING;
  GET DIAGNOSTICS v_event_inserted = ROW_COUNT;

  -- A replay of an already-projected receipt must never re-apply stale consent.
  IF v_event_inserted = 0 THEN
    UPDATE henvalt.shopify_webhook_deliveries
       SET processing_status='PROCESSED',processed_at=COALESCE(processed_at,pg_catalog.now()),
           failure_code=NULL
     WHERE id=v_route.receipt_id;
    RETURN jsonb_build_object('accepted',true,'status','DUPLICATE',
      'consent_state','UNCHANGED','recipient_pii_stored',false);
  END IF;

  SELECT consent_updated_at,marketing_state,observed_at
    INTO v_existing_at,v_existing_state,v_existing_observed_at
  FROM henvalt.shopify_customer_email_consent_v2
  WHERE shopify_connection_id=v_route.connection_id AND customer_identity_id=v_customer_id
  FOR UPDATE;

  IF NOT FOUND THEN
    INSERT INTO henvalt.shopify_customer_email_consent_v2(
      tenant_id,shopify_connection_id,customer_identity_id,marketing_state,
      opt_in_level,consent_updated_at,observed_at,source_delivery_id
    )
    VALUES(v_route.tenant_id,v_route.connection_id,v_customer_id,
           CASE WHEN v_consent_at IS NULL THEN 'UNKNOWN' ELSE v_state END,
           v_opt_in,v_consent_at,v_route.received_at,v_route.receipt_id);
  ELSIF v_consent_at IS NOT NULL AND (v_existing_at IS NULL OR v_consent_at>v_existing_at) THEN
    UPDATE henvalt.shopify_customer_email_consent_v2
       SET marketing_state=v_state,opt_in_level=v_opt_in,consent_updated_at=v_consent_at,
           observed_at=v_route.received_at,source_delivery_id=v_route.receipt_id
     WHERE shopify_connection_id=v_route.connection_id AND customer_identity_id=v_customer_id;
  ELSIF v_consent_at IS NOT NULL AND v_consent_at=v_existing_at
        AND v_state IS DISTINCT FROM v_existing_state THEN
    -- Conflicting evidence at the same timestamp is ambiguous: fail closed.
    UPDATE henvalt.shopify_customer_email_consent_v2
       SET marketing_state='UNKNOWN',opt_in_level=NULL,observed_at=GREATEST(observed_at,v_route.received_at),
           source_delivery_id=v_route.receipt_id
     WHERE shopify_connection_id=v_route.connection_id AND customer_identity_id=v_customer_id;
  ELSIF v_consent_at IS NULL AND v_route.received_at>=v_existing_observed_at THEN
    -- An event without an authoritative timestamp cannot establish current
    -- consent; fail closed rather than retaining a stale SUBSCRIBED state.
    UPDATE henvalt.shopify_customer_email_consent_v2
       SET marketing_state='UNKNOWN',opt_in_level=v_opt_in,consent_updated_at=NULL,
           observed_at=v_route.received_at,source_delivery_id=v_route.receipt_id
     WHERE shopify_connection_id=v_route.connection_id AND customer_identity_id=v_customer_id;
  END IF;

  UPDATE henvalt.shopify_webhook_deliveries
     SET processing_status='PROCESSED',processed_at=pg_catalog.now(),failure_code=NULL,
         metadata=COALESCE(metadata,'{}'::jsonb)||jsonb_build_object('consent_projection','PROCESSED')
   WHERE id=v_route.receipt_id;

  RETURN jsonb_build_object('accepted',true,'status','PROCESSED',
    'consent_state',CASE WHEN v_consent_at IS NULL THEN 'UNKNOWN' ELSE v_state END,
    'customer_identity_id',v_customer_id,'recipient_pii_stored',false);
END;
$function$;

REVOKE ALL ON FUNCTION henvalt.project_verified_shopify_email_consent_v2(text,text,text)
  FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION henvalt.project_verified_shopify_email_consent_v2(text,text,text)
  TO service_role;

COMMIT;

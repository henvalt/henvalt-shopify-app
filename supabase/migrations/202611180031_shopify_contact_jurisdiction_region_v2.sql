-- HENVALT minimal subnational jurisdiction evidence V2.
-- Stores Shopify's region code only; never address, postal code or raw response.
BEGIN;
ALTER TABLE henvalt.shopify_customer_contact_evidence_v2
  ADD COLUMN IF NOT EXISTS region_code text;
ALTER TABLE henvalt.shopify_customer_contact_evidence_v2
  DROP CONSTRAINT IF EXISTS shopify_customer_contact_evidence_v2_region_format;
ALTER TABLE henvalt.shopify_customer_contact_evidence_v2
  ADD CONSTRAINT shopify_customer_contact_evidence_v2_region_format
  CHECK (region_code IS NULL OR region_code ~ '^[A-Z0-9-]{1,12}$');
ALTER TABLE henvalt.shopify_customer_contact_evidence_current_v2
  ADD COLUMN IF NOT EXISTS region_code text;
ALTER TABLE henvalt.shopify_customer_contact_evidence_current_v2
  DROP CONSTRAINT IF EXISTS shopify_customer_contact_evidence_current_v2_region_format;
ALTER TABLE henvalt.shopify_customer_contact_evidence_current_v2
  ADD CONSTRAINT shopify_customer_contact_evidence_current_v2_region_format
  CHECK (region_code IS NULL OR region_code ~ '^[A-Z0-9-]{1,12}$');

CREATE OR REPLACE FUNCTION henvalt.record_shopify_customer_contact_evidence_v3(
 p_connection_id uuid,p_customer_identity_id uuid,p_contact_available boolean,
 p_country_code text,p_region_code text,p_observed_at timestamptz,p_lookup_id uuid
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=''
AS $$
DECLARE v_connection record; v_evidence_id uuid; v_existing_at timestamptz;
 v_current_updated boolean:=false; v_rows integer:=0;
 v_country text; v_region text;
BEGIN
 v_country:=CASE WHEN p_country_code IS NULL THEN NULL ELSE upper(btrim(p_country_code)) END;
 v_region:=CASE WHEN p_region_code IS NULL OR btrim(p_region_code)='' THEN NULL ELSE upper(btrim(p_region_code)) END;
 IF p_connection_id IS NULL OR p_customer_identity_id IS NULL OR p_contact_available IS NULL
    OR p_observed_at IS NULL OR p_lookup_id IS NULL
    OR (v_country IS NOT NULL AND v_country !~ '^[A-Z]{2}$')
    OR (v_region IS NOT NULL AND v_region !~ '^[A-Z0-9-]{1,12}$')
    OR p_observed_at<pg_catalog.now()-interval '5 minutes'
    OR p_observed_at>pg_catalog.now()+interval '1 minute' THEN
   RETURN jsonb_build_object('accepted',false,'code','INVALID_EVIDENCE');
 END IF;
 SELECT sc.tenant_id,sc.active,ar.lifecycle_status,t.status::text tenant_status
 INTO v_connection
 FROM henvalt.shopify_connections sc
 JOIN henvalt.shopify_app_registry ar ON ar.app_key=sc.app_key
 JOIN henvalt.tenants t ON t.id=sc.tenant_id
 WHERE sc.id=p_connection_id FOR SHARE OF sc;
 IF NOT FOUND OR v_connection.active IS DISTINCT FROM true
    OR v_connection.tenant_status<>'ACTIVE' OR v_connection.lifecycle_status<>'active' THEN
   RETURN jsonb_build_object('accepted',false,'code','STORE_OR_APP_INACTIVE');
 END IF;
 IF NOT EXISTS(SELECT 1 FROM henvalt.shopify_customer_identity_v2 ci
   WHERE ci.id=p_customer_identity_id AND ci.tenant_id=v_connection.tenant_id
     AND ci.shopify_connection_id=p_connection_id) THEN
   RETURN jsonb_build_object('accepted',false,'code','CUSTOMER_IDENTITY_SCOPE_MISMATCH');
 END IF;
 INSERT INTO henvalt.shopify_customer_contact_evidence_v2(
  tenant_id,shopify_connection_id,customer_identity_id,contact_available,
  country_code,region_code,observed_at,lookup_id
 ) VALUES(v_connection.tenant_id,p_connection_id,p_customer_identity_id,
  p_contact_available,v_country,v_region,p_observed_at,p_lookup_id)
 ON CONFLICT(shopify_connection_id,lookup_id) DO NOTHING
 RETURNING id INTO v_evidence_id;
 IF v_evidence_id IS NULL THEN
  SELECT e.id INTO v_evidence_id FROM henvalt.shopify_customer_contact_evidence_v2 e
  WHERE e.shopify_connection_id=p_connection_id AND e.lookup_id=p_lookup_id
   AND e.customer_identity_id=p_customer_identity_id
   AND e.contact_available=p_contact_available
   AND e.country_code IS NOT DISTINCT FROM v_country
   AND e.region_code IS NOT DISTINCT FROM v_region;
  IF v_evidence_id IS NULL THEN
   RETURN jsonb_build_object('accepted',false,'code','LOOKUP_ID_REPLAY_MISMATCH');
  END IF;
 END IF;
 SELECT observed_at INTO v_existing_at FROM henvalt.shopify_customer_contact_evidence_current_v2
 WHERE shopify_connection_id=p_connection_id AND customer_identity_id=p_customer_identity_id FOR UPDATE;
 IF NOT FOUND OR p_observed_at>v_existing_at THEN
  INSERT INTO henvalt.shopify_customer_contact_evidence_current_v2(
   tenant_id,shopify_connection_id,customer_identity_id,evidence_id,
   contact_available,country_code,region_code,observed_at,updated_at
  ) VALUES(v_connection.tenant_id,p_connection_id,p_customer_identity_id,v_evidence_id,
   p_contact_available,v_country,v_region,p_observed_at,pg_catalog.now())
  ON CONFLICT(shopify_connection_id,customer_identity_id) DO UPDATE
   SET evidence_id=EXCLUDED.evidence_id,contact_available=EXCLUDED.contact_available,
    country_code=EXCLUDED.country_code,region_code=EXCLUDED.region_code,
    observed_at=EXCLUDED.observed_at,updated_at=pg_catalog.now()
   WHERE EXCLUDED.observed_at>henvalt.shopify_customer_contact_evidence_current_v2.observed_at;
  GET DIAGNOSTICS v_rows=ROW_COUNT; v_current_updated:=v_rows>0;
 END IF;
 RETURN jsonb_build_object('accepted',true,'evidence_id',v_evidence_id,
  'current_updated',v_current_updated,'contact_value_stored',false,
  'address_fields_stored',false,'send_authorized',false,'freshness_seconds',900);
END; $$;
REVOKE ALL ON FUNCTION henvalt.record_shopify_customer_contact_evidence_v3(uuid,uuid,boolean,text,text,timestamptz,uuid)
 FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION henvalt.record_shopify_customer_contact_evidence_v3(uuid,uuid,boolean,text,text,timestamptz,uuid)
 TO service_role;
COMMIT;
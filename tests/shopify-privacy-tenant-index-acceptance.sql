\set ON_ERROR_STOP on

DO $privacy_tenant_index$
DECLARE
  v_definition text;
  v_valid boolean;
  v_ready boolean;
BEGIN
  SELECT pg_get_indexdef(i.indexrelid), i.indisvalid, i.indisready
    INTO v_definition, v_valid, v_ready
    FROM pg_index i
    JOIN pg_class idx ON idx.oid = i.indexrelid
    JOIN pg_class tbl ON tbl.oid = i.indrelid
    JOIN pg_namespace n ON n.oid = tbl.relnamespace
   WHERE n.nspname = 'henvalt'
     AND tbl.relname = 'shopify_privacy_requests'
     AND idx.relname = 'shopify_privacy_requests_tenant_id_idx';

  IF v_definition IS NULL
     OR v_definition NOT LIKE '%USING btree (tenant_id)%'
     OR v_valid IS DISTINCT FROM true
     OR v_ready IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'SHOPIFY_PRIVACY_TENANT_FK_INDEX_MISSING_OR_INVALID: %', v_definition;
  END IF;

  RAISE NOTICE 'SHOPIFY_PRIVACY_TENANT_FK_INDEX_ACCEPTANCE_PASSED';
END;
$privacy_tenant_index$;

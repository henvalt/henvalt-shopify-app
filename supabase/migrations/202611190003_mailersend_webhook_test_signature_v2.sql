-- HENVALT MailerSend webhook URL-validation ping signature compatibility V2.
-- The legacy candidate function had a mistyped fixed MailerSend test secret.
-- Keep normal event verification unchanged; handle only webhook.test here.
BEGIN;

ALTER FUNCTION henvalt.ingest_mailersend_webhook_v2(text,text,text)
  RENAME TO ingest_mailersend_webhook_v2_legacy;

CREATE OR REPLACE FUNCTION henvalt.ingest_mailersend_webhook_v2(
  p_provider_account_key text,
  p_signature_hex text,
  p_raw_body_base64 text
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=''
AS $function$
DECLARE
  v_body bytea;
  v_payload jsonb;
  v_event_type text;
  v_provider_status text;
  v_expected bytea;
  v_provided bytea;
  v_diff integer:=0;
  v_i integer;
BEGIN
  IF current_setting('request.jwt.claim.role',true) IS DISTINCT FROM 'service_role' THEN
    RAISE EXCEPTION 'service_role_required' USING ERRCODE='42501';
  END IF;

  IF p_provider_account_key IS NULL
     OR p_provider_account_key !~ '^[A-Za-z0-9_-]{24,96}$'
     OR p_signature_hex IS NULL
     OR p_signature_hex !~ '^[0-9a-fA-F]{64}$'
     OR p_raw_body_base64 IS NULL
     OR length(p_raw_body_base64)>2800000 THEN
    RETURN jsonb_build_object('accepted',false,'code','INVALID_REQUEST');
  END IF;

  BEGIN
    v_body:=pg_catalog.decode(p_raw_body_base64,'base64');
    v_payload:=pg_catalog.convert_from(v_body,'UTF8')::jsonb;
    v_provided:=pg_catalog.decode(p_signature_hex,'hex');
  EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('accepted',false,'code','INVALID_BODY');
  END;

  IF pg_catalog.octet_length(v_body)=0 OR pg_catalog.octet_length(v_body)>2097152
     OR pg_catalog.jsonb_typeof(v_payload)<>'object' THEN
    RETURN jsonb_build_object('accepted',false,'code','INVALID_BODY_SIZE');
  END IF;

  v_event_type:=NULLIF(v_payload->>'type','');
  IF v_event_type IS DISTINCT FROM 'webhook.test' THEN
    RETURN henvalt.ingest_mailersend_webhook_v2_legacy(
      p_provider_account_key,p_signature_hex,p_raw_body_base64
    );
  END IF;

  SELECT r.status INTO v_provider_status
  FROM henvalt.shopify_mailer_provider_registry_v2 r
  WHERE r.provider_account_key=p_provider_account_key
  FOR UPDATE;
  IF NOT FOUND OR v_provider_status NOT IN ('ACTIVE','PENDING') THEN
    RETURN jsonb_build_object('accepted',false,'code','PROVIDER_ACCOUNT_INACTIVE');
  END IF;

  -- MailerSend's documented URL-validation test signing secret.
  v_expected:=extensions.hmac(
    v_body,
    pg_catalog.convert_to('test_Am3L1GuOIc4blLUuHqAPxxwkZaJyEk8','UTF8'),
    'sha256'
  );
  FOR v_i IN 0..31 LOOP
    v_diff:=v_diff | (pg_catalog.get_byte(v_expected,v_i) # pg_catalog.get_byte(v_provided,v_i));
  END LOOP;
  IF v_diff<>0 THEN
    RETURN jsonb_build_object('accepted',false,'code','SIGNATURE_INVALID');
  END IF;

  RETURN jsonb_build_object(
    'accepted',true,
    'status','WEBHOOK_TEST_VERIFIED',
    'event_persisted',false,
    'recipient_pii_stored',false
  );
END;
$function$;

REVOKE ALL ON FUNCTION henvalt.ingest_mailersend_webhook_v2(text,text,text)
  FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION henvalt.ingest_mailersend_webhook_v2(text,text,text)
  TO service_role;

COMMIT;

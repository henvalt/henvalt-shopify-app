-- HENVALT exact-store intervention, provider-event and suppression foundation V2.
-- PREPARATION ONLY. Depends on candidate opportunity migration 013.
-- Provider webhook bodies and recipient email are never persisted.

BEGIN;

CREATE UNIQUE INDEX IF NOT EXISTS shopify_recovery_opportunity_v2_id_tenant_connection_uidx
  ON henvalt.shopify_recovery_opportunity_v2(id,tenant_id,shopify_connection_id);

CREATE TABLE IF NOT EXISTS henvalt.shopify_recovery_intervention_v2 (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id uuid NOT NULL,
  shopify_connection_id uuid NOT NULL,
  opportunity_id uuid NOT NULL,
  customer_identity_id uuid NOT NULL,
  step_number integer NOT NULL CHECK(step_number BETWEEN 1 AND 10),
  status text NOT NULL DEFAULT 'READY_FOR_AUTHORIZATION'
    CHECK(status IN ('READY_FOR_AUTHORIZATION','AUTHORIZED','SUBMITTED','DELIVERED','FAILED','CANCELLED','AMBIGUOUS')),
  scheduled_at timestamptz NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT shopify_recovery_intervention_v2_opportunity_fkey
    FOREIGN KEY(opportunity_id,tenant_id,shopify_connection_id)
    REFERENCES henvalt.shopify_recovery_opportunity_v2(id,tenant_id,shopify_connection_id)
    ON UPDATE RESTRICT ON DELETE RESTRICT,
  CONSTRAINT shopify_recovery_intervention_v2_customer_fkey
    FOREIGN KEY(customer_identity_id,tenant_id,shopify_connection_id)
    REFERENCES henvalt.shopify_customer_identity_v2(id,tenant_id,shopify_connection_id)
    ON UPDATE RESTRICT ON DELETE RESTRICT,
  CONSTRAINT shopify_recovery_intervention_v2_opportunity_step_uidx
    UNIQUE(opportunity_id,step_number),
  CONSTRAINT shopify_recovery_intervention_v2_id_lineage_uidx
    UNIQUE(id,tenant_id,shopify_connection_id,customer_identity_id)
);

CREATE TABLE IF NOT EXISTS henvalt.shopify_mailer_provider_registry_v2 (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id uuid NOT NULL REFERENCES henvalt.tenants(id) ON UPDATE RESTRICT ON DELETE RESTRICT,
  provider_account_key text NOT NULL UNIQUE,
  mailersend_domain_id text NOT NULL,
  webhook_secret_ref text NOT NULL,
  recipient_fingerprint_secret_ref text NOT NULL,
  status text NOT NULL DEFAULT 'PENDING' CHECK(status IN ('PENDING','ACTIVE','PAUSED','RETIRED')),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT shopify_mailer_provider_registry_v2_key_format
    CHECK(provider_account_key ~ '^[a-zA-Z0-9_-]{24,96}$'),
  CONSTRAINT shopify_mailer_provider_registry_v2_domain_nonempty
    CHECK(length(btrim(mailersend_domain_id)) BETWEEN 1 AND 100),
  CONSTRAINT shopify_mailer_provider_registry_v2_secret_refs
    CHECK(length(btrim(webhook_secret_ref))>0 AND length(btrim(recipient_fingerprint_secret_ref))>0)
);

CREATE UNIQUE INDEX IF NOT EXISTS shopify_mailer_provider_registry_v2_key_tenant_uidx
  ON henvalt.shopify_mailer_provider_registry_v2(provider_account_key,tenant_id);

CREATE TABLE IF NOT EXISTS henvalt.shopify_recovery_send_attempt_v2 (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id uuid NOT NULL,
  shopify_connection_id uuid NOT NULL,
  customer_identity_id uuid NOT NULL,
  intervention_id uuid NOT NULL,
  provider_account_key text NOT NULL REFERENCES henvalt.shopify_mailer_provider_registry_v2(provider_account_key)
    ON UPDATE RESTRICT ON DELETE RESTRICT,
  idempotency_key text NOT NULL,
  provider_message_id text,
  provider_email_id text,
  status text NOT NULL DEFAULT 'AUTHORIZED'
    CHECK(status IN ('AUTHORIZED','SUBMITTED','DELIVERED','SOFT_BOUNCED','HARD_BOUNCED','UNSUBSCRIBED','COMPLAINED','FAILED','AMBIGUOUS')),
  submitted_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT shopify_recovery_send_attempt_v2_intervention_fkey
    FOREIGN KEY(intervention_id,tenant_id,shopify_connection_id,customer_identity_id)
    REFERENCES henvalt.shopify_recovery_intervention_v2(id,tenant_id,shopify_connection_id,customer_identity_id)
    ON UPDATE RESTRICT ON DELETE RESTRICT,
  CONSTRAINT shopify_recovery_send_attempt_v2_id_lineage_uidx
    UNIQUE(id,tenant_id,shopify_connection_id),
  CONSTRAINT shopify_recovery_send_attempt_v2_provider_tenant_fkey
    FOREIGN KEY(provider_account_key,tenant_id)
    REFERENCES henvalt.shopify_mailer_provider_registry_v2(provider_account_key,tenant_id)
    ON UPDATE RESTRICT ON DELETE RESTRICT,
  CONSTRAINT shopify_recovery_send_attempt_v2_idempotency_uidx
    UNIQUE(shopify_connection_id,idempotency_key),
  CONSTRAINT shopify_recovery_send_attempt_v2_provider_message_uidx
    UNIQUE(provider_account_key,provider_message_id)
);

CREATE TABLE IF NOT EXISTS henvalt.shopify_mailer_provider_events_v2 (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  provider_account_key text NOT NULL REFERENCES henvalt.shopify_mailer_provider_registry_v2(provider_account_key)
    ON UPDATE RESTRICT ON DELETE RESTRICT,
  provider_event_id text NOT NULL,
  provider_message_id text,
  provider_email_id text,
  event_type text NOT NULL,
  occurred_at timestamptz,
  body_sha256 text NOT NULL CHECK(body_sha256 ~ '^[0-9a-f]{64}$'),
  tenant_id uuid,
  shopify_connection_id uuid,
  send_attempt_id uuid,
  processing_status text NOT NULL DEFAULT 'UNMATCHED'
    CHECK(processing_status IN ('UNMATCHED','PROCESSED','IGNORED','REJECTED')),
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT shopify_mailer_provider_events_v2_delivery_uidx
    UNIQUE(provider_account_key,provider_event_id),
  CONSTRAINT shopify_mailer_provider_events_v2_id_lineage_uidx
    UNIQUE(id,tenant_id,shopify_connection_id),
  CONSTRAINT shopify_mailer_provider_events_v2_send_attempt_fkey
    FOREIGN KEY(send_attempt_id,tenant_id,shopify_connection_id)
    REFERENCES henvalt.shopify_recovery_send_attempt_v2(id,tenant_id,shopify_connection_id)
    ON UPDATE RESTRICT ON DELETE RESTRICT
);

CREATE TABLE IF NOT EXISTS henvalt.shopify_delivery_suppressions_v2 (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id uuid NOT NULL,
  shopify_connection_id uuid NOT NULL,
  customer_identity_id uuid NOT NULL,
  recipient_fingerprint bytea,
  suppression_type text NOT NULL CHECK(suppression_type IN ('UNSUBSCRIBED','SPAM_COMPLAINT','HARD_BOUNCE')),
  source_send_attempt_id uuid NOT NULL,
  source_provider_event_id uuid NOT NULL,
  active boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT shopify_delivery_suppressions_v2_customer_fkey
    FOREIGN KEY(customer_identity_id,tenant_id,shopify_connection_id)
    REFERENCES henvalt.shopify_customer_identity_v2(id,tenant_id,shopify_connection_id)
    ON UPDATE RESTRICT ON DELETE RESTRICT,
  CONSTRAINT shopify_delivery_suppressions_v2_attempt_fkey
    FOREIGN KEY(source_send_attempt_id,tenant_id,shopify_connection_id)
    REFERENCES henvalt.shopify_recovery_send_attempt_v2(id,tenant_id,shopify_connection_id)
    ON UPDATE RESTRICT ON DELETE RESTRICT,
  CONSTRAINT shopify_delivery_suppressions_v2_event_fkey
    FOREIGN KEY(source_provider_event_id,tenant_id,shopify_connection_id)
    REFERENCES henvalt.shopify_mailer_provider_events_v2(id,tenant_id,shopify_connection_id)
    ON UPDATE RESTRICT ON DELETE RESTRICT,
  CONSTRAINT shopify_delivery_suppressions_v2_unique
    UNIQUE(shopify_connection_id,customer_identity_id,suppression_type,source_provider_event_id)
);

CREATE INDEX IF NOT EXISTS shopify_delivery_suppressions_v2_active_customer_idx
  ON henvalt.shopify_delivery_suppressions_v2(shopify_connection_id,customer_identity_id)
  WHERE active IS TRUE;
CREATE INDEX IF NOT EXISTS shopify_recovery_send_attempt_v2_message_idx
  ON henvalt.shopify_recovery_send_attempt_v2(provider_account_key,provider_message_id)
  WHERE provider_message_id IS NOT NULL;

ALTER TABLE henvalt.shopify_recovery_intervention_v2 ENABLE ROW LEVEL SECURITY;
ALTER TABLE henvalt.shopify_mailer_provider_registry_v2 ENABLE ROW LEVEL SECURITY;
ALTER TABLE henvalt.shopify_recovery_send_attempt_v2 ENABLE ROW LEVEL SECURITY;
ALTER TABLE henvalt.shopify_mailer_provider_events_v2 ENABLE ROW LEVEL SECURITY;
ALTER TABLE henvalt.shopify_delivery_suppressions_v2 ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON henvalt.shopify_recovery_intervention_v2 FROM PUBLIC,anon,authenticated,service_role;
REVOKE ALL ON henvalt.shopify_mailer_provider_registry_v2 FROM PUBLIC,anon,authenticated,service_role;
REVOKE ALL ON henvalt.shopify_recovery_send_attempt_v2 FROM PUBLIC,anon,authenticated,service_role;
REVOKE ALL ON henvalt.shopify_mailer_provider_events_v2 FROM PUBLIC,anon,authenticated,service_role;
REVOKE ALL ON henvalt.shopify_delivery_suppressions_v2 FROM PUBLIC,anon,authenticated,service_role;

COMMENT ON TABLE henvalt.shopify_mailer_provider_registry_v2 IS
  'Server-only MailerSend V2 webhook identity. Stores Vault references only; webhook signing and recipient fingerprint keys are separate secrets.';
COMMENT ON TABLE henvalt.shopify_mailer_provider_events_v2 IS
  'Minimal idempotent provider event inbox. Never stores raw payload, recipient email, subject, IP, user agent or clicked URL.';
COMMENT ON TABLE henvalt.shopify_delivery_suppressions_v2 IS
  'Exact-store suppression evidence. Recipient fingerprint is keyed HMAC, not a plaintext or unsalted email hash.';

CREATE OR REPLACE FUNCTION henvalt.ingest_mailersend_webhook_v2(
  p_provider_account_key text,
  p_signature_hex text,
  p_raw_body_base64 text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_provider record;
  v_signing_secret text;
  v_fingerprint_secret text;
  v_body bytea;
  v_payload jsonb;
  v_expected bytea;
  v_provided bytea;
  v_diff integer:=0;
  v_i integer;
  v_event_id text;
  v_message_id text;
  v_email_id text;
  v_event_type text;
  v_domain_id text;
  v_recipient text;
  v_fingerprint bytea;
  v_occurred_at timestamptz;
  v_digest text;
  v_inserted uuid;
  v_attempt record;
  v_suppression_type text;
BEGIN
  IF p_provider_account_key IS NULL OR length(p_provider_account_key)<24 OR length(p_provider_account_key)>96
     OR p_signature_hex IS NULL OR p_signature_hex !~ '^[0-9a-fA-F]{64}$'
     OR p_raw_body_base64 IS NULL OR length(p_raw_body_base64)>2800000 THEN
    RETURN jsonb_build_object('accepted',false,'code','INVALID_REQUEST');
  END IF;
  BEGIN
    v_body:=pg_catalog.decode(p_raw_body_base64,'base64');
    v_payload:=pg_catalog.convert_from(v_body,'UTF8')::jsonb;
    v_provided:=pg_catalog.decode(p_signature_hex,'hex');
  EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('accepted',false,'code','INVALID_BODY');
  END;
  IF pg_catalog.octet_length(v_body)=0 OR pg_catalog.octet_length(v_body)>2097152 THEN
    RETURN jsonb_build_object('accepted',false,'code','INVALID_BODY_SIZE');
  END IF;

  SELECT r.id,r.tenant_id,r.mailersend_domain_id,r.webhook_secret_ref,
         r.recipient_fingerprint_secret_ref,r.status
    INTO v_provider
  FROM henvalt.shopify_mailer_provider_registry_v2 r
  WHERE r.provider_account_key=p_provider_account_key
  FOR UPDATE;
  IF NOT FOUND OR v_provider.status<>'ACTIVE' THEN
    RETURN jsonb_build_object('accepted',false,'code','PROVIDER_ACCOUNT_INACTIVE');
  END IF;

  SELECT decrypted_secret INTO v_signing_secret FROM vault.decrypted_secrets
  WHERE name=v_provider.webhook_secret_ref LIMIT 1;
  SELECT decrypted_secret INTO v_fingerprint_secret FROM vault.decrypted_secrets
  WHERE name=v_provider.recipient_fingerprint_secret_ref LIMIT 1;
  IF v_signing_secret IS NULL OR v_signing_secret='' OR v_fingerprint_secret IS NULL OR length(v_fingerprint_secret)<32 THEN
    RETURN jsonb_build_object('accepted',false,'code','PROVIDER_SECRET_NOT_CONFIGURED');
  END IF;

  v_expected:=extensions.hmac(v_body,pg_catalog.convert_to(v_signing_secret,'UTF8'),'sha256');
  FOR v_i IN 0..31 LOOP
    v_diff:=v_diff | (pg_catalog.get_byte(v_expected,v_i) # pg_catalog.get_byte(v_provided,v_i));
  END LOOP;
  IF v_diff<>0 THEN RETURN jsonb_build_object('accepted',false,'code','SIGNATURE_INVALID'); END IF;

  v_event_type:=NULLIF(v_payload->>'type','');
  v_event_id:=NULLIF(v_payload->'data'->>'id','');
  v_message_id:=NULLIF(v_payload->'data'->>'message_id','');
  v_email_id:=NULLIF(v_payload->'data'->>'email_id','');
  v_domain_id:=NULLIF(v_payload->'data'->>'domain_id','');
  v_recipient:=lower(NULLIF(pg_catalog.btrim(COALESCE(v_payload->'data'->>'recipient',v_payload->'data'->>'email')),''));
  IF v_event_type IS NULL OR v_event_id IS NULL OR length(v_event_id)>160 THEN
    RETURN jsonb_build_object('accepted',false,'code','EVENT_IDENTITY_MISSING');
  END IF;
  IF v_domain_id IS DISTINCT FROM v_provider.mailersend_domain_id THEN
    RETURN jsonb_build_object('accepted',false,'code','PROVIDER_DOMAIN_MISMATCH');
  END IF;
  BEGIN
    v_occurred_at:=NULLIF(v_payload->>'created_at','')::timestamptz;
  EXCEPTION WHEN OTHERS THEN v_occurred_at:=NULL;
  END;
  v_digest:=pg_catalog.encode(extensions.digest(v_body,'sha256'),'hex');

  INSERT INTO henvalt.shopify_mailer_provider_events_v2(
    provider_account_key,provider_event_id,provider_message_id,provider_email_id,
    event_type,occurred_at,body_sha256,processing_status
  ) VALUES (
    p_provider_account_key,v_event_id,v_message_id,v_email_id,v_event_type,
    v_occurred_at,v_digest,'UNMATCHED'
  )
  ON CONFLICT(provider_account_key,provider_event_id) DO NOTHING
  RETURNING id INTO v_inserted;

  IF v_inserted IS NULL THEN
    IF EXISTS(
      SELECT 1 FROM henvalt.shopify_mailer_provider_events_v2
      WHERE provider_account_key=p_provider_account_key
        AND provider_event_id=v_event_id AND body_sha256<>v_digest
    ) THEN
      RETURN jsonb_build_object('accepted',false,'code','EVENT_ID_BODY_MISMATCH');
    END IF;
    RETURN jsonb_build_object('accepted',true,'status','DUPLICATE');
  END IF;

  IF v_message_id IS NULL THEN
    UPDATE henvalt.shopify_mailer_provider_events_v2 SET processing_status='IGNORED' WHERE id=v_inserted;
    RETURN jsonb_build_object('accepted',true,'status','UNMATCHED');
  END IF;

  SELECT a.id,a.tenant_id,a.shopify_connection_id,a.customer_identity_id,a.status
    INTO v_attempt
  FROM henvalt.shopify_recovery_send_attempt_v2 a
  WHERE a.provider_account_key=p_provider_account_key
    AND a.provider_message_id=v_message_id
  FOR UPDATE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('accepted',true,'status','UNMATCHED');
  END IF;

  UPDATE henvalt.shopify_mailer_provider_events_v2
     SET tenant_id=v_attempt.tenant_id,
         shopify_connection_id=v_attempt.shopify_connection_id,
         send_attempt_id=v_attempt.id,
         processing_status='PROCESSED'
   WHERE id=v_inserted;

  v_suppression_type:=CASE v_event_type
    WHEN 'activity.unsubscribed' THEN 'UNSUBSCRIBED'
    WHEN 'activity.spam_complaint' THEN 'SPAM_COMPLAINT'
    WHEN 'activity.hard_bounced' THEN 'HARD_BOUNCE'
    ELSE NULL END;

  IF v_event_type='activity.delivered' THEN
    UPDATE henvalt.shopify_recovery_send_attempt_v2 SET status='DELIVERED',updated_at=pg_catalog.now()
    WHERE id=v_attempt.id AND status IN ('SUBMITTED','AMBIGUOUS');
  ELSIF v_event_type='activity.soft_bounced' THEN
    UPDATE henvalt.shopify_recovery_send_attempt_v2 SET status='SOFT_BOUNCED',updated_at=pg_catalog.now()
    WHERE id=v_attempt.id AND status IN ('SUBMITTED','AMBIGUOUS');
  ELSIF v_event_type='activity.hard_bounced' THEN
    UPDATE henvalt.shopify_recovery_send_attempt_v2 SET status='HARD_BOUNCED',updated_at=pg_catalog.now()
    WHERE id=v_attempt.id;
  ELSIF v_event_type='activity.unsubscribed' THEN
    UPDATE henvalt.shopify_recovery_send_attempt_v2 SET status='UNSUBSCRIBED',updated_at=pg_catalog.now()
    WHERE id=v_attempt.id;
  ELSIF v_event_type='activity.spam_complaint' THEN
    UPDATE henvalt.shopify_recovery_send_attempt_v2 SET status='COMPLAINED',updated_at=pg_catalog.now()
    WHERE id=v_attempt.id;
  END IF;

  IF v_suppression_type IS NOT NULL THEN
    IF v_recipient IS NOT NULL AND length(v_recipient)<=254 THEN
      v_fingerprint:=extensions.hmac(pg_catalog.convert_to(v_recipient,'UTF8'),pg_catalog.convert_to(v_fingerprint_secret,'UTF8'),'sha256');
    END IF;
    INSERT INTO henvalt.shopify_delivery_suppressions_v2(
      tenant_id,shopify_connection_id,customer_identity_id,recipient_fingerprint,
      suppression_type,source_send_attempt_id,source_provider_event_id
    ) VALUES (
      v_attempt.tenant_id,v_attempt.shopify_connection_id,v_attempt.customer_identity_id,
      v_fingerprint,v_suppression_type,v_attempt.id,v_inserted
    )
    ON CONFLICT(shopify_connection_id,customer_identity_id,suppression_type,source_provider_event_id)
    DO NOTHING;
  END IF;

  RETURN jsonb_build_object('accepted',true,'status','PROCESSED',
    'suppression_applied',v_suppression_type IS NOT NULL,
    'recipient_pii_stored',false);
END;
$function$;

REVOKE ALL ON FUNCTION henvalt.ingest_mailersend_webhook_v2(text,text,text)
  FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION henvalt.ingest_mailersend_webhook_v2(text,text,text)
  TO service_role;

COMMIT;

-- HENVALT pixel cart/browse delivery permit + cost reservation boundary V2.
-- Independent from checkout intervention/permit chain. No email or provider call here.
BEGIN;

CREATE TABLE IF NOT EXISTS henvalt.shopify_pixel_delivery_permits_v2 (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 tenant_id uuid NOT NULL,
 shopify_connection_id uuid NOT NULL,
 opportunity_id uuid NOT NULL REFERENCES henvalt.shopify_recovery_opportunity_v2(id) ON UPDATE RESTRICT ON DELETE RESTRICT,
 pixel_candidate_id uuid NOT NULL REFERENCES henvalt.shopify_pixel_recovery_candidate_v2(id) ON UPDATE RESTRICT ON DELETE RESTRICT,
 customer_identity_id uuid NOT NULL REFERENCES henvalt.shopify_customer_identity_v2(id) ON UPDATE RESTRICT ON DELETE RESTRICT,
 provider_account_key text NOT NULL,
 sender_profile_id uuid NOT NULL REFERENCES henvalt.shopify_sender_profiles_v2(id) ON UPDATE RESTRICT ON DELETE RESTRICT,
 permit_token_sha256 text NOT NULL UNIQUE CHECK(permit_token_sha256 ~ '^[0-9a-f]{64}$'),
 recipient_fingerprint bytea NOT NULL CHECK(pg_catalog.octet_length(recipient_fingerprint)=32),
 expires_at timestamptz NOT NULL,
 consumed_at timestamptz,
 pixel_send_attempt_id uuid,
 created_at timestamptz NOT NULL DEFAULT pg_catalog.now(),
 CONSTRAINT shopify_pixel_delivery_permits_connection_fk FOREIGN KEY(shopify_connection_id,tenant_id)
  REFERENCES henvalt.shopify_connections(id,tenant_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
 CONSTRAINT shopify_pixel_delivery_permits_provider_fk FOREIGN KEY(provider_account_key,tenant_id)
  REFERENCES henvalt.shopify_mailer_provider_registry_v2(provider_account_key,tenant_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
 CONSTRAINT shopify_pixel_delivery_permits_sender_fk FOREIGN KEY(sender_profile_id,tenant_id,shopify_connection_id)
  REFERENCES henvalt.shopify_sender_profiles_v2(id,tenant_id,shopify_connection_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
 CONSTRAINT shopify_pixel_delivery_permits_opportunity_scope UNIQUE(id,tenant_id,shopify_connection_id,opportunity_id)
);
-- Composite keys make tenant/store/customer lineage enforceable by PostgreSQL,
-- not merely by the SECURITY DEFINER routines.
CREATE UNIQUE INDEX IF NOT EXISTS shopify_recovery_opportunity_v2_id_tenant_connection_uidx
 ON henvalt.shopify_recovery_opportunity_v2(id,tenant_id,shopify_connection_id);
CREATE UNIQUE INDEX IF NOT EXISTS shopify_customer_identity_v2_id_tenant_connection_uidx
 ON henvalt.shopify_customer_identity_v2(id,tenant_id,shopify_connection_id);

CREATE UNIQUE INDEX IF NOT EXISTS shopify_recovery_opportunity_v2_pixel_delivery_lineage_uidx
 ON henvalt.shopify_recovery_opportunity_v2(id,tenant_id,shopify_connection_id,pixel_candidate_id,customer_identity_id);
ALTER TABLE henvalt.shopify_pixel_delivery_permits_v2
 ADD CONSTRAINT shopify_pixel_permit_opportunity_scope_fk
  FOREIGN KEY(opportunity_id,tenant_id,shopify_connection_id)
  REFERENCES henvalt.shopify_recovery_opportunity_v2(id,tenant_id,shopify_connection_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
 ADD CONSTRAINT shopify_pixel_permit_opportunity_lineage_fk
  FOREIGN KEY(opportunity_id,tenant_id,shopify_connection_id,pixel_candidate_id,customer_identity_id)
  REFERENCES henvalt.shopify_recovery_opportunity_v2(id,tenant_id,shopify_connection_id,pixel_candidate_id,customer_identity_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
 ADD CONSTRAINT shopify_pixel_permit_candidate_scope_fk
  FOREIGN KEY(pixel_candidate_id,tenant_id,shopify_connection_id)
  REFERENCES henvalt.shopify_pixel_recovery_candidate_v2(id,tenant_id,shopify_connection_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
 ADD CONSTRAINT shopify_pixel_permit_customer_scope_fk
  FOREIGN KEY(customer_identity_id,tenant_id,shopify_connection_id)
  REFERENCES henvalt.shopify_customer_identity_v2(id,tenant_id,shopify_connection_id) ON UPDATE RESTRICT ON DELETE RESTRICT;

ALTER TABLE henvalt.shopify_pixel_send_attempts_v2
 ADD CONSTRAINT shopify_pixel_attempt_opportunity_scope_fk
  FOREIGN KEY(opportunity_id,tenant_id,shopify_connection_id)
  REFERENCES henvalt.shopify_recovery_opportunity_v2(id,tenant_id,shopify_connection_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
 ADD CONSTRAINT shopify_pixel_attempt_candidate_scope_fk
  FOREIGN KEY(pixel_candidate_id,tenant_id,shopify_connection_id)
  REFERENCES henvalt.shopify_pixel_recovery_candidate_v2(id,tenant_id,shopify_connection_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
 ADD CONSTRAINT shopify_pixel_attempt_customer_scope_fk
  FOREIGN KEY(customer_identity_id,tenant_id,shopify_connection_id)
  REFERENCES henvalt.shopify_customer_identity_v2(id,tenant_id,shopify_connection_id) ON UPDATE RESTRICT ON DELETE RESTRICT;

CREATE INDEX IF NOT EXISTS shopify_pixel_delivery_permits_pending_idx
 ON henvalt.shopify_pixel_delivery_permits_v2(expires_at) WHERE consumed_at IS NULL;

CREATE TABLE IF NOT EXISTS henvalt.shopify_pixel_send_attempts_v2 (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 tenant_id uuid NOT NULL,
 shopify_connection_id uuid NOT NULL,
 opportunity_id uuid NOT NULL REFERENCES henvalt.shopify_recovery_opportunity_v2(id) ON UPDATE RESTRICT ON DELETE RESTRICT,
 pixel_candidate_id uuid NOT NULL REFERENCES henvalt.shopify_pixel_recovery_candidate_v2(id) ON UPDATE RESTRICT ON DELETE RESTRICT,
 customer_identity_id uuid NOT NULL REFERENCES henvalt.shopify_customer_identity_v2(id) ON UPDATE RESTRICT ON DELETE RESTRICT,
 provider_account_key text NOT NULL,
 idempotency_key text NOT NULL,
 status text NOT NULL DEFAULT 'AUTHORIZED' CHECK(status IN ('AUTHORIZED','SUBMITTED','FAILED','AMBIGUOUS')),
 provider_message_reference text,
 created_at timestamptz NOT NULL DEFAULT pg_catalog.now(),
 updated_at timestamptz NOT NULL DEFAULT pg_catalog.now(),
 CONSTRAINT shopify_pixel_send_attempts_connection_fk FOREIGN KEY(shopify_connection_id,tenant_id)
  REFERENCES henvalt.shopify_connections(id,tenant_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
 CONSTRAINT shopify_pixel_send_attempts_provider_fk FOREIGN KEY(provider_account_key,tenant_id)
  REFERENCES henvalt.shopify_mailer_provider_registry_v2(provider_account_key,tenant_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
 CONSTRAINT shopify_pixel_send_attempts_idempotency UNIQUE(shopify_connection_id,idempotency_key),
 CONSTRAINT shopify_pixel_send_attempts_opportunity_once UNIQUE(opportunity_id)
);
CREATE INDEX IF NOT EXISTS shopify_pixel_send_attempts_tenant_month_idx
 ON henvalt.shopify_pixel_send_attempts_v2(tenant_id,created_at);

CREATE TABLE IF NOT EXISTS henvalt.shopify_pixel_delivery_cost_reservations_v2 (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 tenant_id uuid NOT NULL,
 shopify_connection_id uuid NOT NULL,
 pixel_send_attempt_id uuid NOT NULL UNIQUE REFERENCES henvalt.shopify_pixel_send_attempts_v2(id) ON UPDATE RESTRICT ON DELETE RESTRICT,
 provider_account_key text NOT NULL,
 period_start timestamptz NOT NULL,
 amount numeric(18,6) NOT NULL CHECK(amount>0),
 currency text NOT NULL CHECK(currency ~ '^[A-Z]{3}$'),
 status text NOT NULL DEFAULT 'RESERVED' CHECK(status IN ('RESERVED','SETTLED','RELEASED')),
 created_at timestamptz NOT NULL DEFAULT pg_catalog.now(),
 updated_at timestamptz NOT NULL DEFAULT pg_catalog.now(),
 FOREIGN KEY(shopify_connection_id,tenant_id) REFERENCES henvalt.shopify_connections(id,tenant_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
 FOREIGN KEY(provider_account_key,tenant_id) REFERENCES henvalt.shopify_mailer_provider_registry_v2(provider_account_key,tenant_id) ON UPDATE RESTRICT ON DELETE RESTRICT
);

ALTER TABLE henvalt.shopify_pixel_delivery_permits_v2 ENABLE ROW LEVEL SECURITY;
ALTER TABLE henvalt.shopify_pixel_send_attempts_v2 ENABLE ROW LEVEL SECURITY;
CREATE UNIQUE INDEX IF NOT EXISTS shopify_pixel_send_attempts_v2_id_scope_uidx
 ON henvalt.shopify_pixel_send_attempts_v2(id,tenant_id,shopify_connection_id);
ALTER TABLE henvalt.shopify_pixel_delivery_cost_reservations_v2
 ADD CONSTRAINT shopify_pixel_cost_attempt_scope_fk
 FOREIGN KEY(pixel_send_attempt_id,tenant_id,shopify_connection_id)
 REFERENCES henvalt.shopify_pixel_send_attempts_v2(id,tenant_id,shopify_connection_id) ON UPDATE RESTRICT ON DELETE RESTRICT;
ALTER TABLE henvalt.shopify_pixel_delivery_cost_reservations_v2 ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON henvalt.shopify_pixel_delivery_permits_v2,henvalt.shopify_pixel_send_attempts_v2,henvalt.shopify_pixel_delivery_cost_reservations_v2 FROM PUBLIC,anon,authenticated,service_role;

COMMENT ON TABLE henvalt.shopify_pixel_delivery_permits_v2 IS 'Independent short-lived single-use cart/browse delivery permit. Never references checkout IDs or intervention IDs.';
COMMENT ON TABLE henvalt.shopify_pixel_send_attempts_v2 IS 'Cart/browse provider attempt ledger, independent of checkout interventions and attempts.';
COMMENT ON TABLE henvalt.shopify_pixel_delivery_cost_reservations_v2 IS 'Merchant-wide monetary reservations for pixel attempts; shares the billing account lock and cap with checkout attempts.';

CREATE OR REPLACE FUNCTION henvalt.reserve_shopify_pixel_delivery_cost_v2()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=''
AS $function$
DECLARE b record; p record; period timestamptz; reserved numeric(18,6); monthly bigint;
BEGIN
 IF NEW.status<>'AUTHORIZED' THEN RAISE EXCEPTION 'pixel cost reservation requires AUTHORIZED attempt'; END IF;
 SELECT * INTO b FROM henvalt.billing_accounts WHERE tenant_id=NEW.tenant_id FOR UPDATE;
 IF NOT FOUND OR b.status<>'ACTIVE' OR b.test_mode IS DISTINCT FROM false
   OR b.usage_cap_amount IS NULL OR b.usage_cap_amount<=0
   OR b.monthly_email_limit IS NULL OR b.monthly_email_limit<=0
   OR b.currency IS NULL OR pg_catalog.upper(pg_catalog.btrim(b.currency::text)) !~ '^[A-Z]{3}$'
 THEN RAISE EXCEPTION 'merchant billing account is not eligible for pixel delivery'; END IF;
 SELECT * INTO p FROM henvalt.shopify_mailer_provider_registry_v2
 WHERE tenant_id=NEW.tenant_id AND provider_account_key=NEW.provider_account_key AND status='ACTIVE' FOR SHARE;
 IF NOT FOUND OR p.email_unit_cost_amount IS NULL OR p.email_unit_cost_amount<=0
   OR p.email_unit_cost_currency<>pg_catalog.upper(pg_catalog.btrim(b.currency::text))
 THEN RAISE EXCEPTION 'pixel provider cost must match merchant billing currency'; END IF;
 period:=pg_catalog.date_trunc('month',NEW.created_at);
 SELECT coalesce(sum(x.amount),0) INTO reserved FROM (
  SELECT r.amount FROM henvalt.shopify_delivery_cost_reservations_v2 r
   WHERE r.tenant_id=NEW.tenant_id AND r.period_start=period AND r.currency=pg_catalog.upper(pg_catalog.btrim(b.currency::text)) AND r.status IN ('RESERVED','SETTLED')
  UNION ALL
  SELECT r.amount FROM henvalt.shopify_pixel_delivery_cost_reservations_v2 r
   WHERE r.tenant_id=NEW.tenant_id AND r.period_start=period AND r.currency=pg_catalog.upper(pg_catalog.btrim(b.currency::text)) AND r.status IN ('RESERVED','SETTLED')
 ) x;
 IF reserved+p.email_unit_cost_amount>b.usage_cap_amount THEN RAISE EXCEPTION 'merchant monetary usage cap would be exceeded'; END IF;
 SELECT
  (SELECT count(*) FROM henvalt.shopify_recovery_send_attempt_v2 a WHERE a.tenant_id=NEW.tenant_id AND a.created_at>=period AND a.created_at<period+interval '1 month')
 + (SELECT count(*) FROM henvalt.shopify_pixel_send_attempts_v2 a WHERE a.tenant_id=NEW.tenant_id AND a.created_at>=period AND a.created_at<period+interval '1 month')
 INTO monthly;
 IF monthly>b.monthly_email_limit THEN RAISE EXCEPTION 'merchant monthly email limit would be exceeded'; END IF;
 INSERT INTO henvalt.shopify_pixel_delivery_cost_reservations_v2(tenant_id,shopify_connection_id,pixel_send_attempt_id,provider_account_key,period_start,amount,currency,status)
 VALUES(NEW.tenant_id,NEW.shopify_connection_id,NEW.id,NEW.provider_account_key,period,p.email_unit_cost_amount,pg_catalog.upper(pg_catalog.btrim(b.currency::text)),'RESERVED');
 RETURN NEW;
END;$function$;

CREATE OR REPLACE FUNCTION henvalt.sync_shopify_pixel_delivery_cost_reservation_v2()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=''
AS $function$
BEGIN
 IF NEW.status IS DISTINCT FROM OLD.status THEN
  UPDATE henvalt.shopify_pixel_delivery_cost_reservations_v2
   SET status=CASE WHEN NEW.status='SUBMITTED' THEN 'SETTLED' WHEN NEW.status='FAILED' THEN 'RELEASED' WHEN NEW.status='AMBIGUOUS' THEN 'RESERVED' ELSE status END,
       updated_at=pg_catalog.now()
   WHERE pixel_send_attempt_id=NEW.id AND tenant_id=NEW.tenant_id AND shopify_connection_id=NEW.shopify_connection_id
     AND status IN ('RESERVED','SETTLED');
 END IF;
 RETURN NEW;
END;$function$;
CREATE TRIGGER shopify_pixel_delivery_cost_reserve_v2 AFTER INSERT ON henvalt.shopify_pixel_send_attempts_v2
 FOR EACH ROW EXECUTE FUNCTION henvalt.reserve_shopify_pixel_delivery_cost_v2();
CREATE TRIGGER shopify_pixel_delivery_cost_sync_v2 AFTER UPDATE OF status ON henvalt.shopify_pixel_send_attempts_v2
 FOR EACH ROW EXECUTE FUNCTION henvalt.sync_shopify_pixel_delivery_cost_reservation_v2();
REVOKE ALL ON FUNCTION henvalt.reserve_shopify_pixel_delivery_cost_v2() FROM PUBLIC,anon,authenticated,service_role;
REVOKE ALL ON FUNCTION henvalt.sync_shopify_pixel_delivery_cost_reservation_v2() FROM PUBLIC,anon,authenticated,service_role;

CREATE OR REPLACE FUNCTION henvalt.issue_shopify_pixel_delivery_permit_v2(
 p_opportunity_id uuid,p_provider_account_key text,p_sender_profile_id uuid,p_recipient_fingerprint_hex text
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=''
AS $function$
DECLARE o record; s record; token text; pid uuid;
BEGIN
 IF current_setting('request.jwt.claim.role',true) IS DISTINCT FROM 'service_role' THEN RAISE EXCEPTION 'service_role_required' USING ERRCODE='42501'; END IF;
 IF p_opportunity_id IS NULL OR p_provider_account_key IS NULL OR p_sender_profile_id IS NULL
  OR p_recipient_fingerprint_hex IS NULL OR p_recipient_fingerprint_hex !~ '^[0-9a-fA-F]{64}
  RETURN jsonb_build_object('authorized',false,'code','INVALID_REQUEST');
 END IF;
 SELECT * INTO o FROM henvalt.shopify_recovery_opportunity_v2
 WHERE id=p_opportunity_id AND opportunity_type IN ('ABANDONED_CART','BROWSE_ABANDONMENT')
 FOR UPDATE;
 IF NOT FOUND THEN RETURN jsonb_build_object('authorized',false,'code','PIXEL_OPPORTUNITY_NOT_FOUND'); END IF;
 IF EXISTS(SELECT 1 FROM henvalt.shopify_pixel_send_attempts_v2 a WHERE a.opportunity_id=o.id)
  OR EXISTS(SELECT 1 FROM henvalt.shopify_pixel_delivery_permits_v2 p WHERE p.opportunity_id=o.id AND p.expires_at>pg_catalog.now())
 THEN RETURN jsonb_build_object('authorized',false,'code','PIXEL_DELIVERY_ALREADY_CLAIMED'); END IF;
 IF EXISTS(SELECT 1 FROM henvalt.shopify_delivery_suppressions_v2 x WHERE x.tenant_id=o.tenant_id AND x.shopify_connection_id=o.shopify_connection_id AND x.recipient_fingerprint=pg_catalog.decode(p_recipient_fingerprint_hex,'hex') AND x.active IS TRUE)
 THEN RETURN jsonb_build_object('authorized',false,'code','RECIPIENT_SUPPRESSED'); END IF;
 IF NOT EXISTS(SELECT 1 FROM henvalt.shopify_mailer_provider_registry_v2 pr JOIN henvalt.shopify_sender_profiles_v2 sp
   ON sp.provider_account_key=pr.provider_account_key AND sp.tenant_id=pr.tenant_id
   WHERE pr.tenant_id=o.tenant_id AND pr.provider_account_key=p_provider_account_key AND pr.status='ACTIVE'
    AND pr.email_unit_cost_amount>0 AND sp.id=p_sender_profile_id AND sp.shopify_connection_id=o.shopify_connection_id
    AND sp.status='ACTIVE' AND sp.verified_at IS NOT NULL)
 THEN RETURN jsonb_build_object('authorized',false,'code','PROVIDER_OR_SENDER_NOT_READY'); END IF;
 IF NOT EXISTS(SELECT 1 FROM henvalt.billing_accounts b WHERE b.tenant_id=o.tenant_id AND b.status='ACTIVE'
   AND b.test_mode IS FALSE AND b.henvalt_percentage>0 AND b.usage_cap_amount>0 AND b.monthly_email_limit>0)
 THEN RETURN jsonb_build_object('authorized',false,'code','BILLING_NOT_READY'); END IF;
 s:=henvalt.assess_shopify_pixel_delivery_eligibility_v2(o.id);
 IF coalesce((s->>'eligible')::boolean,false) IS NOT TRUE THEN
  RETURN jsonb_build_object('authorized',false,'code',coalesce(s->>'code','PIXEL_NOT_ELIGIBLE'));
 END IF;
 token:=pg_catalog.encode(extensions.gen_random_bytes(32),'hex');
 INSERT INTO henvalt.shopify_pixel_delivery_permits_v2(tenant_id,shopify_connection_id,opportunity_id,pixel_candidate_id,customer_identity_id,
  provider_account_key,sender_profile_id,permit_token_sha256,recipient_fingerprint,expires_at)
 VALUES(o.tenant_id,o.shopify_connection_id,o.id,o.pixel_candidate_id,o.customer_identity_id,p_provider_account_key,p_sender_profile_id,
  pg_catalog.encode(extensions.digest(pg_catalog.convert_to(token,'UTF8'),'sha256'),'hex'),
  pg_catalog.decode(p_recipient_fingerprint_hex,'hex'),pg_catalog.now()+interval '2 minutes')
 RETURNING id INTO pid;
 RETURN jsonb_build_object('authorized',true,'permit_id',pid,'permit_token',token,'expires_in_seconds',120,
  'delivery_authorized',false,'provider_cost_reserved',false,'recipient_email_returned',false);
END;$function$;

CREATE OR REPLACE FUNCTION henvalt.consume_shopify_pixel_delivery_permit_v2(p_permit_token text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=''
AS $function$
DECLARE p henvalt.shopify_pixel_delivery_permits_v2%ROWTYPE; o record; assessment jsonb; aid uuid; idem text;
BEGIN
 IF current_setting('request.jwt.claim.role',true) IS DISTINCT FROM 'service_role' THEN RAISE EXCEPTION 'service_role_required' USING ERRCODE='42501'; END IF;
 IF p_permit_token IS NULL OR p_permit_token !~ '^[0-9a-f]{64}$' THEN RETURN jsonb_build_object('consumed',false,'code','INVALID_PERMIT'); END IF;
 SELECT * INTO p FROM henvalt.shopify_pixel_delivery_permits_v2
 WHERE permit_token_sha256=pg_catalog.encode(extensions.digest(pg_catalog.convert_to(p_permit_token,'UTF8'),'sha256'),'hex') FOR UPDATE;
 IF NOT FOUND THEN RETURN jsonb_build_object('consumed',false,'code','PERMIT_NOT_FOUND'); END IF;
 IF p.consumed_at IS NOT NULL THEN RETURN jsonb_build_object('consumed',false,'code','PERMIT_ALREADY_USED'); END IF;
 IF p.expires_at<=pg_catalog.now() THEN RETURN jsonb_build_object('consumed',false,'code','PERMIT_EXPIRED'); END IF;
 SELECT * INTO o FROM henvalt.shopify_recovery_opportunity_v2
 WHERE id=p.opportunity_id AND tenant_id=p.tenant_id AND shopify_connection_id=p.shopify_connection_id
  AND pixel_candidate_id=p.pixel_candidate_id AND customer_identity_id=p.customer_identity_id
  AND opportunity_type IN ('ABANDONED_CART','BROWSE_ABANDONMENT') FOR UPDATE;
 IF NOT FOUND THEN RETURN jsonb_build_object('consumed',false,'code','PIXEL_OPPORTUNITY_SCOPE_CHANGED'); END IF;
 assessment:=henvalt.assess_shopify_pixel_delivery_eligibility_v2(o.id);
 IF coalesce((assessment->>'eligible')::boolean,false) IS NOT TRUE THEN
  RETURN jsonb_build_object('consumed',false,'code',coalesce(assessment->>'code','PIXEL_GATE_CHANGED'));
 END IF;
 IF EXISTS(SELECT 1 FROM henvalt.shopify_delivery_suppressions_v2 x
  WHERE x.tenant_id=p.tenant_id AND x.shopify_connection_id=p.shopify_connection_id
   AND x.active IS TRUE AND (x.customer_identity_id=p.customer_identity_id OR x.recipient_fingerprint=p.recipient_fingerprint))
 THEN RETURN jsonb_build_object('consumed',false,'code','RECIPIENT_SUPPRESSION_CHANGED'); END IF;
 idem:='v2-pixel-opportunity:'||p.opportunity_id::text;
 INSERT INTO henvalt.shopify_pixel_send_attempts_v2(tenant_id,shopify_connection_id,opportunity_id,pixel_candidate_id,customer_identity_id,provider_account_key,idempotency_key,status)
 VALUES(p.tenant_id,p.shopify_connection_id,p.opportunity_id,p.pixel_candidate_id,p.customer_identity_id,p.provider_account_key,idem,'AUTHORIZED')
 ON CONFLICT(opportunity_id) DO NOTHING RETURNING id INTO aid;
 IF aid IS NULL THEN RETURN jsonb_build_object('consumed',false,'code','PIXEL_DELIVERY_ALREADY_CLAIMED'); END IF;
 UPDATE henvalt.shopify_pixel_delivery_permits_v2 SET consumed_at=pg_catalog.now(),pixel_send_attempt_id=aid
 WHERE id=p.id AND consumed_at IS NULL;
 RETURN jsonb_build_object('consumed',true,'pixel_send_attempt_id',aid,'opportunity_id',p.opportunity_id,
  'recipient_email_returned',false,'provider_submission_performed',false,'provider_cost_reserved',true);
END;$function$;

CREATE OR REPLACE FUNCTION henvalt.record_shopify_pixel_send_attempt_result_v2(
 p_send_attempt_id uuid,p_status text,p_provider_message_reference text DEFAULT NULL
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=''
AS $function$
DECLARE a record;
BEGIN
 IF current_setting('request.jwt.claim.role',true) IS DISTINCT FROM 'service_role' THEN RAISE EXCEPTION 'service_role_required' USING ERRCODE='42501'; END IF;
 IF p_status NOT IN ('SUBMITTED','FAILED','AMBIGUOUS') OR p_send_attempt_id IS NULL
  OR (p_provider_message_reference IS NOT NULL AND length(p_provider_message_reference)>240)
 THEN RETURN jsonb_build_object('recorded',false,'code','INVALID_RESULT'); END IF;
 SELECT * INTO a FROM henvalt.shopify_pixel_send_attempts_v2 WHERE id=p_send_attempt_id FOR UPDATE;
 IF NOT FOUND THEN RETURN jsonb_build_object('recorded',false,'code','ATTEMPT_NOT_FOUND'); END IF;
 IF a.status NOT IN ('AUTHORIZED','AMBIGUOUS') OR (a.status='AMBIGUOUS' AND p_status='AMBIGUOUS') THEN RETURN jsonb_build_object('recorded',false,'code','ATTEMPT_ALREADY_FINALIZED'); END IF;
 UPDATE henvalt.shopify_pixel_send_attempts_v2 SET status=p_status,provider_message_reference=coalesce(p_provider_message_reference,provider_message_reference),updated_at=pg_catalog.now() WHERE id=a.id;
 RETURN jsonb_build_object('recorded',true,'status',p_status,'provider_cost_state',CASE WHEN p_status='SUBMITTED' THEN 'SETTLED' WHEN p_status='FAILED' THEN 'RELEASED' ELSE 'RESERVED' END);
END;$function$;

-- Extend the existing checkout reservation trigger so checkout and pixel
-- reservations serialize against the same merchant cap in both directions.
CREATE OR REPLACE FUNCTION henvalt.reserve_shopify_delivery_cost_v2()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=''
AS $function$
DECLARE b henvalt.billing_accounts%ROWTYPE; p henvalt.shopify_mailer_provider_registry_v2%ROWTYPE;
 period timestamptz; reserved numeric(18,6); monthly bigint;
BEGIN
 IF NEW.status<>'AUTHORIZED' THEN RAISE EXCEPTION 'delivery cost reservation requires AUTHORIZED send attempt'; END IF;
 SELECT * INTO b FROM henvalt.billing_accounts WHERE tenant_id=NEW.tenant_id FOR UPDATE;
 IF NOT FOUND OR b.status<>'ACTIVE' OR b.test_mode IS DISTINCT FROM false
  OR b.usage_cap_amount IS NULL OR b.usage_cap_amount<=0
  OR b.monthly_email_limit IS NULL OR b.monthly_email_limit<=0 OR b.currency IS NULL
  OR pg_catalog.upper(pg_catalog.btrim(b.currency::text)) !~ '^[A-Z]{3}(uuid,text,uuid,text) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION henvalt.consume_shopify_pixel_delivery_permit_v2(text) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION henvalt.record_shopify_pixel_send_attempt_result_v2(uuid,text,text) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION henvalt.issue_shopify_pixel_delivery_permit_v2(uuid,text,uuid,text) TO service_role;
GRANT EXECUTE ON FUNCTION henvalt.consume_shopify_pixel_delivery_permit_v2(text) TO service_role;
GRANT EXECUTE ON FUNCTION henvalt.record_shopify_pixel_send_attempt_result_v2(uuid,text,text) TO service_role;
COMMIT;
 THEN
  RETURN jsonb_build_object('authorized',false,'code','INVALID_REQUEST');
 END IF;
 SELECT * INTO o FROM henvalt.shopify_recovery_opportunity_v2
 WHERE id=p_opportunity_id AND opportunity_type IN ('ABANDONED_CART','BROWSE_ABANDONMENT')
 FOR UPDATE;
 IF NOT FOUND THEN RETURN jsonb_build_object('authorized',false,'code','PIXEL_OPPORTUNITY_NOT_FOUND'); END IF;
 IF EXISTS(SELECT 1 FROM henvalt.shopify_pixel_send_attempts_v2 a WHERE a.opportunity_id=o.id)
  OR EXISTS(SELECT 1 FROM henvalt.shopify_pixel_delivery_permits_v2 p WHERE p.opportunity_id=o.id AND p.expires_at>pg_catalog.now())
 THEN RETURN jsonb_build_object('authorized',false,'code','PIXEL_DELIVERY_ALREADY_CLAIMED'); END IF;
 IF EXISTS(SELECT 1 FROM henvalt.shopify_delivery_suppressions_v2 x WHERE x.tenant_id=o.tenant_id AND x.shopify_connection_id=o.shopify_connection_id AND x.recipient_fingerprint=pg_catalog.decode(p_recipient_fingerprint_hex,'hex') AND x.active IS TRUE)
 THEN RETURN jsonb_build_object('authorized',false,'code','RECIPIENT_SUPPRESSED'); END IF;
 IF NOT EXISTS(SELECT 1 FROM henvalt.shopify_mailer_provider_registry_v2 pr JOIN henvalt.shopify_sender_profiles_v2 sp
   ON sp.provider_account_key=pr.provider_account_key AND sp.tenant_id=pr.tenant_id
   WHERE pr.tenant_id=o.tenant_id AND pr.provider_account_key=p_provider_account_key AND pr.status='ACTIVE'
    AND pr.email_unit_cost_amount>0 AND sp.id=p_sender_profile_id AND sp.shopify_connection_id=o.shopify_connection_id
    AND sp.status='ACTIVE' AND sp.verified_at IS NOT NULL)
 THEN RETURN jsonb_build_object('authorized',false,'code','PROVIDER_OR_SENDER_NOT_READY'); END IF;
 IF NOT EXISTS(SELECT 1 FROM henvalt.billing_accounts b WHERE b.tenant_id=o.tenant_id AND b.status='ACTIVE'
   AND b.test_mode IS FALSE AND b.henvalt_percentage>0 AND b.usage_cap_amount>0 AND b.monthly_email_limit>0)
 THEN RETURN jsonb_build_object('authorized',false,'code','BILLING_NOT_READY'); END IF;
 s:=henvalt.assess_shopify_pixel_delivery_eligibility_v2(o.id);
 IF coalesce((s->>'eligible')::boolean,false) IS NOT TRUE THEN
  RETURN jsonb_build_object('authorized',false,'code',coalesce(s->>'code','PIXEL_NOT_ELIGIBLE'));
 END IF;
 token:=pg_catalog.encode(extensions.gen_random_bytes(32),'hex');
 INSERT INTO henvalt.shopify_pixel_delivery_permits_v2(tenant_id,shopify_connection_id,opportunity_id,pixel_candidate_id,customer_identity_id,
  provider_account_key,sender_profile_id,permit_token_sha256,recipient_fingerprint,expires_at)
 VALUES(o.tenant_id,o.shopify_connection_id,o.id,o.pixel_candidate_id,o.customer_identity_id,p_provider_account_key,p_sender_profile_id,
  pg_catalog.encode(extensions.digest(pg_catalog.convert_to(token,'UTF8'),'sha256'),'hex'),
  pg_catalog.decode(p_recipient_fingerprint_hex,'hex'),pg_catalog.now()+interval '2 minutes')
 RETURNING id INTO pid;
 RETURN jsonb_build_object('authorized',true,'permit_id',pid,'permit_token',token,'expires_in_seconds',120,
  'delivery_authorized',false,'provider_cost_reserved',false,'recipient_email_returned',false);
END;$function$;

CREATE OR REPLACE FUNCTION henvalt.consume_shopify_pixel_delivery_permit_v2(p_permit_token text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=''
AS $function$
DECLARE p henvalt.shopify_pixel_delivery_permits_v2%ROWTYPE; o record; assessment jsonb; aid uuid; idem text;
BEGIN
 IF current_setting('request.jwt.claim.role',true) IS DISTINCT FROM 'service_role' THEN RAISE EXCEPTION 'service_role_required' USING ERRCODE='42501'; END IF;
 IF p_permit_token IS NULL OR p_permit_token !~ '^[0-9a-f]{64}$' THEN RETURN jsonb_build_object('consumed',false,'code','INVALID_PERMIT'); END IF;
 SELECT * INTO p FROM henvalt.shopify_pixel_delivery_permits_v2
 WHERE permit_token_sha256=pg_catalog.encode(extensions.digest(pg_catalog.convert_to(p_permit_token,'UTF8'),'sha256'),'hex') FOR UPDATE;
 IF NOT FOUND THEN RETURN jsonb_build_object('consumed',false,'code','PERMIT_NOT_FOUND'); END IF;
 IF p.consumed_at IS NOT NULL THEN RETURN jsonb_build_object('consumed',false,'code','PERMIT_ALREADY_USED'); END IF;
 IF p.expires_at<=pg_catalog.now() THEN RETURN jsonb_build_object('consumed',false,'code','PERMIT_EXPIRED'); END IF;
 SELECT * INTO o FROM henvalt.shopify_recovery_opportunity_v2
 WHERE id=p.opportunity_id AND tenant_id=p.tenant_id AND shopify_connection_id=p.shopify_connection_id
  AND pixel_candidate_id=p.pixel_candidate_id AND customer_identity_id=p.customer_identity_id
  AND opportunity_type IN ('ABANDONED_CART','BROWSE_ABANDONMENT') FOR UPDATE;
 IF NOT FOUND THEN RETURN jsonb_build_object('consumed',false,'code','PIXEL_OPPORTUNITY_SCOPE_CHANGED'); END IF;
 assessment:=henvalt.assess_shopify_pixel_delivery_eligibility_v2(o.id);
 IF coalesce((assessment->>'eligible')::boolean,false) IS NOT TRUE THEN
  RETURN jsonb_build_object('consumed',false,'code',coalesce(assessment->>'code','PIXEL_GATE_CHANGED'));
 END IF;
 IF EXISTS(SELECT 1 FROM henvalt.shopify_delivery_suppressions_v2 x
  WHERE x.tenant_id=p.tenant_id AND x.shopify_connection_id=p.shopify_connection_id
   AND x.active IS TRUE AND (x.customer_identity_id=p.customer_identity_id OR x.recipient_fingerprint=p.recipient_fingerprint))
 THEN RETURN jsonb_build_object('consumed',false,'code','RECIPIENT_SUPPRESSION_CHANGED'); END IF;
 idem:='v2-pixel-opportunity:'||p.opportunity_id::text;
 INSERT INTO henvalt.shopify_pixel_send_attempts_v2(tenant_id,shopify_connection_id,opportunity_id,pixel_candidate_id,customer_identity_id,provider_account_key,idempotency_key,status)
 VALUES(p.tenant_id,p.shopify_connection_id,p.opportunity_id,p.pixel_candidate_id,p.customer_identity_id,p.provider_account_key,idem,'AUTHORIZED')
 ON CONFLICT(opportunity_id) DO NOTHING RETURNING id INTO aid;
 IF aid IS NULL THEN RETURN jsonb_build_object('consumed',false,'code','PIXEL_DELIVERY_ALREADY_CLAIMED'); END IF;
 UPDATE henvalt.shopify_pixel_delivery_permits_v2 SET consumed_at=pg_catalog.now(),pixel_send_attempt_id=aid
 WHERE id=p.id AND consumed_at IS NULL;
 RETURN jsonb_build_object('consumed',true,'pixel_send_attempt_id',aid,'opportunity_id',p.opportunity_id,
  'recipient_email_returned',false,'provider_submission_performed',false,'provider_cost_reserved',true);
END;$function$;

CREATE OR REPLACE FUNCTION henvalt.record_shopify_pixel_send_attempt_result_v2(
 p_send_attempt_id uuid,p_status text,p_provider_message_reference text DEFAULT NULL
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=''
AS $function$
DECLARE a record;
BEGIN
 IF current_setting('request.jwt.claim.role',true) IS DISTINCT FROM 'service_role' THEN RAISE EXCEPTION 'service_role_required' USING ERRCODE='42501'; END IF;
 IF p_status NOT IN ('SUBMITTED','FAILED','AMBIGUOUS') OR p_send_attempt_id IS NULL
  OR (p_provider_message_reference IS NOT NULL AND length(p_provider_message_reference)>240)
 THEN RETURN jsonb_build_object('recorded',false,'code','INVALID_RESULT'); END IF;
 SELECT * INTO a FROM henvalt.shopify_pixel_send_attempts_v2 WHERE id=p_send_attempt_id FOR UPDATE;
 IF NOT FOUND THEN RETURN jsonb_build_object('recorded',false,'code','ATTEMPT_NOT_FOUND'); END IF;
 IF a.status<>'AUTHORIZED' THEN RETURN jsonb_build_object('recorded',false,'code','ATTEMPT_ALREADY_FINALIZED'); END IF;
 UPDATE henvalt.shopify_pixel_send_attempts_v2 SET status=p_status,provider_message_reference=p_provider_message_reference,updated_at=pg_catalog.now() WHERE id=a.id;
 RETURN jsonb_build_object('recorded',true,'status',p_status,'provider_cost_state',CASE WHEN p_status='SUBMITTED' THEN 'SETTLED' WHEN p_status='FAILED' THEN 'RELEASED' ELSE 'RESERVED' END);
END;$function$;

REVOKE ALL ON FUNCTION henvalt.issue_shopify_pixel_delivery_permit_v2(uuid,text,uuid,text) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION henvalt.consume_shopify_pixel_delivery_permit_v2(text) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION henvalt.record_shopify_pixel_send_attempt_result_v2(uuid,text,text) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION henvalt.issue_shopify_pixel_delivery_permit_v2(uuid,text,uuid,text) TO service_role;
GRANT EXECUTE ON FUNCTION henvalt.consume_shopify_pixel_delivery_permit_v2(text) TO service_role;
GRANT EXECUTE ON FUNCTION henvalt.record_shopify_pixel_send_attempt_result_v2(uuid,text,text) TO service_role;
COMMIT;

 THEN RAISE EXCEPTION 'merchant billing account is not eligible for delivery reservation'; END IF;
 SELECT * INTO p FROM henvalt.shopify_mailer_provider_registry_v2
 WHERE tenant_id=NEW.tenant_id AND provider_account_key=NEW.provider_account_key AND status='ACTIVE' FOR SHARE;
 IF NOT FOUND OR p.email_unit_cost_amount IS NULL OR p.email_unit_cost_amount<=0
  OR p.email_unit_cost_currency IS NULL OR p.email_unit_cost_currency<>pg_catalog.upper(pg_catalog.btrim(b.currency::text))
 THEN RAISE EXCEPTION 'provider unit cost must be configured in merchant billing currency'; END IF;
 period:=pg_catalog.date_trunc('month',NEW.created_at);
 SELECT coalesce(sum(x.amount),0) INTO reserved FROM (
  SELECT r.amount FROM henvalt.shopify_delivery_cost_reservations_v2 r
   WHERE r.tenant_id=NEW.tenant_id AND r.period_start=period AND r.currency=pg_catalog.upper(pg_catalog.btrim(b.currency::text)) AND r.status IN ('RESERVED','SETTLED')
  UNION ALL
  SELECT r.amount FROM henvalt.shopify_pixel_delivery_cost_reservations_v2 r
   WHERE r.tenant_id=NEW.tenant_id AND r.period_start=period AND r.currency=pg_catalog.upper(pg_catalog.btrim(b.currency::text)) AND r.status IN ('RESERVED','SETTLED')
 ) x;
 IF reserved+p.email_unit_cost_amount>b.usage_cap_amount THEN RAISE EXCEPTION 'merchant monetary usage cap would be exceeded'; END IF;
 SELECT
  (SELECT count(*) FROM henvalt.shopify_recovery_send_attempt_v2 a WHERE a.tenant_id=NEW.tenant_id AND a.created_at>=period AND a.created_at<period+interval '1 month')
 + (SELECT count(*) FROM henvalt.shopify_pixel_send_attempts_v2 a WHERE a.tenant_id=NEW.tenant_id AND a.created_at>=period AND a.created_at<period+interval '1 month')
 INTO monthly;
 IF monthly>b.monthly_email_limit THEN RAISE EXCEPTION 'merchant monthly email limit would be exceeded'; END IF;
 INSERT INTO henvalt.shopify_delivery_cost_reservations_v2(tenant_id,shopify_connection_id,send_attempt_id,provider_account_key,period_start,amount,currency,status)
 VALUES(NEW.tenant_id,NEW.shopify_connection_id,NEW.id,NEW.provider_account_key,period,p.email_unit_cost_amount,pg_catalog.upper(pg_catalog.btrim(b.currency::text)),'RESERVED');
 RETURN NEW;
END;$function$;

REVOKE ALL ON FUNCTION henvalt.issue_shopify_pixel_delivery_permit_v2(uuid,text,uuid,text) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION henvalt.consume_shopify_pixel_delivery_permit_v2(text) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION henvalt.record_shopify_pixel_send_attempt_result_v2(uuid,text,text) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION henvalt.issue_shopify_pixel_delivery_permit_v2(uuid,text,uuid,text) TO service_role;
GRANT EXECUTE ON FUNCTION henvalt.consume_shopify_pixel_delivery_permit_v2(text) TO service_role;
GRANT EXECUTE ON FUNCTION henvalt.record_shopify_pixel_send_attempt_result_v2(uuid,text,text) TO service_role;
COMMIT;
 THEN
  RETURN jsonb_build_object('authorized',false,'code','INVALID_REQUEST');
 END IF;
 SELECT * INTO o FROM henvalt.shopify_recovery_opportunity_v2
 WHERE id=p_opportunity_id AND opportunity_type IN ('ABANDONED_CART','BROWSE_ABANDONMENT')
 FOR UPDATE;
 IF NOT FOUND THEN RETURN jsonb_build_object('authorized',false,'code','PIXEL_OPPORTUNITY_NOT_FOUND'); END IF;
 IF EXISTS(SELECT 1 FROM henvalt.shopify_pixel_send_attempts_v2 a WHERE a.opportunity_id=o.id)
  OR EXISTS(SELECT 1 FROM henvalt.shopify_pixel_delivery_permits_v2 p WHERE p.opportunity_id=o.id AND p.expires_at>pg_catalog.now())
 THEN RETURN jsonb_build_object('authorized',false,'code','PIXEL_DELIVERY_ALREADY_CLAIMED'); END IF;
 IF EXISTS(SELECT 1 FROM henvalt.shopify_delivery_suppressions_v2 x WHERE x.tenant_id=o.tenant_id AND x.shopify_connection_id=o.shopify_connection_id AND x.recipient_fingerprint=pg_catalog.decode(p_recipient_fingerprint_hex,'hex') AND x.active IS TRUE)
 THEN RETURN jsonb_build_object('authorized',false,'code','RECIPIENT_SUPPRESSED'); END IF;
 IF NOT EXISTS(SELECT 1 FROM henvalt.shopify_mailer_provider_registry_v2 pr JOIN henvalt.shopify_sender_profiles_v2 sp
   ON sp.provider_account_key=pr.provider_account_key AND sp.tenant_id=pr.tenant_id
   WHERE pr.tenant_id=o.tenant_id AND pr.provider_account_key=p_provider_account_key AND pr.status='ACTIVE'
    AND pr.email_unit_cost_amount>0 AND sp.id=p_sender_profile_id AND sp.shopify_connection_id=o.shopify_connection_id
    AND sp.status='ACTIVE' AND sp.verified_at IS NOT NULL)
 THEN RETURN jsonb_build_object('authorized',false,'code','PROVIDER_OR_SENDER_NOT_READY'); END IF;
 IF NOT EXISTS(SELECT 1 FROM henvalt.billing_accounts b WHERE b.tenant_id=o.tenant_id AND b.status='ACTIVE'
   AND b.test_mode IS FALSE AND b.henvalt_percentage>0 AND b.usage_cap_amount>0 AND b.monthly_email_limit>0)
 THEN RETURN jsonb_build_object('authorized',false,'code','BILLING_NOT_READY'); END IF;
 s:=henvalt.assess_shopify_pixel_delivery_eligibility_v2(o.id);
 IF coalesce((s->>'eligible')::boolean,false) IS NOT TRUE THEN
  RETURN jsonb_build_object('authorized',false,'code',coalesce(s->>'code','PIXEL_NOT_ELIGIBLE'));
 END IF;
 token:=pg_catalog.encode(extensions.gen_random_bytes(32),'hex');
 INSERT INTO henvalt.shopify_pixel_delivery_permits_v2(tenant_id,shopify_connection_id,opportunity_id,pixel_candidate_id,customer_identity_id,
  provider_account_key,sender_profile_id,permit_token_sha256,recipient_fingerprint,expires_at)
 VALUES(o.tenant_id,o.shopify_connection_id,o.id,o.pixel_candidate_id,o.customer_identity_id,p_provider_account_key,p_sender_profile_id,
  pg_catalog.encode(extensions.digest(pg_catalog.convert_to(token,'UTF8'),'sha256'),'hex'),
  pg_catalog.decode(p_recipient_fingerprint_hex,'hex'),pg_catalog.now()+interval '2 minutes')
 RETURNING id INTO pid;
 RETURN jsonb_build_object('authorized',true,'permit_id',pid,'permit_token',token,'expires_in_seconds',120,
  'delivery_authorized',false,'provider_cost_reserved',false,'recipient_email_returned',false);
END;$function$;

CREATE OR REPLACE FUNCTION henvalt.consume_shopify_pixel_delivery_permit_v2(p_permit_token text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=''
AS $function$
DECLARE p henvalt.shopify_pixel_delivery_permits_v2%ROWTYPE; o record; assessment jsonb; aid uuid; idem text;
BEGIN
 IF current_setting('request.jwt.claim.role',true) IS DISTINCT FROM 'service_role' THEN RAISE EXCEPTION 'service_role_required' USING ERRCODE='42501'; END IF;
 IF p_permit_token IS NULL OR p_permit_token !~ '^[0-9a-f]{64}$' THEN RETURN jsonb_build_object('consumed',false,'code','INVALID_PERMIT'); END IF;
 SELECT * INTO p FROM henvalt.shopify_pixel_delivery_permits_v2
 WHERE permit_token_sha256=pg_catalog.encode(extensions.digest(pg_catalog.convert_to(p_permit_token,'UTF8'),'sha256'),'hex') FOR UPDATE;
 IF NOT FOUND THEN RETURN jsonb_build_object('consumed',false,'code','PERMIT_NOT_FOUND'); END IF;
 IF p.consumed_at IS NOT NULL THEN RETURN jsonb_build_object('consumed',false,'code','PERMIT_ALREADY_USED'); END IF;
 IF p.expires_at<=pg_catalog.now() THEN RETURN jsonb_build_object('consumed',false,'code','PERMIT_EXPIRED'); END IF;
 SELECT * INTO o FROM henvalt.shopify_recovery_opportunity_v2
 WHERE id=p.opportunity_id AND tenant_id=p.tenant_id AND shopify_connection_id=p.shopify_connection_id
  AND pixel_candidate_id=p.pixel_candidate_id AND customer_identity_id=p.customer_identity_id
  AND opportunity_type IN ('ABANDONED_CART','BROWSE_ABANDONMENT') FOR UPDATE;
 IF NOT FOUND THEN RETURN jsonb_build_object('consumed',false,'code','PIXEL_OPPORTUNITY_SCOPE_CHANGED'); END IF;
 assessment:=henvalt.assess_shopify_pixel_delivery_eligibility_v2(o.id);
 IF coalesce((assessment->>'eligible')::boolean,false) IS NOT TRUE THEN
  RETURN jsonb_build_object('consumed',false,'code',coalesce(assessment->>'code','PIXEL_GATE_CHANGED'));
 END IF;
 IF EXISTS(SELECT 1 FROM henvalt.shopify_delivery_suppressions_v2 x
  WHERE x.tenant_id=p.tenant_id AND x.shopify_connection_id=p.shopify_connection_id
   AND x.active IS TRUE AND (x.customer_identity_id=p.customer_identity_id OR x.recipient_fingerprint=p.recipient_fingerprint))
 THEN RETURN jsonb_build_object('consumed',false,'code','RECIPIENT_SUPPRESSION_CHANGED'); END IF;
 idem:='v2-pixel-opportunity:'||p.opportunity_id::text;
 INSERT INTO henvalt.shopify_pixel_send_attempts_v2(tenant_id,shopify_connection_id,opportunity_id,pixel_candidate_id,customer_identity_id,provider_account_key,idempotency_key,status)
 VALUES(p.tenant_id,p.shopify_connection_id,p.opportunity_id,p.pixel_candidate_id,p.customer_identity_id,p.provider_account_key,idem,'AUTHORIZED')
 ON CONFLICT(opportunity_id) DO NOTHING RETURNING id INTO aid;
 IF aid IS NULL THEN RETURN jsonb_build_object('consumed',false,'code','PIXEL_DELIVERY_ALREADY_CLAIMED'); END IF;
 UPDATE henvalt.shopify_pixel_delivery_permits_v2 SET consumed_at=pg_catalog.now(),pixel_send_attempt_id=aid
 WHERE id=p.id AND consumed_at IS NULL;
 RETURN jsonb_build_object('consumed',true,'pixel_send_attempt_id',aid,'opportunity_id',p.opportunity_id,
  'recipient_email_returned',false,'provider_submission_performed',false,'provider_cost_reserved',true);
END;$function$;

CREATE OR REPLACE FUNCTION henvalt.record_shopify_pixel_send_attempt_result_v2(
 p_send_attempt_id uuid,p_status text,p_provider_message_reference text DEFAULT NULL
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=''
AS $function$
DECLARE a record;
BEGIN
 IF current_setting('request.jwt.claim.role',true) IS DISTINCT FROM 'service_role' THEN RAISE EXCEPTION 'service_role_required' USING ERRCODE='42501'; END IF;
 IF p_status NOT IN ('SUBMITTED','FAILED','AMBIGUOUS') OR p_send_attempt_id IS NULL
  OR (p_provider_message_reference IS NOT NULL AND length(p_provider_message_reference)>240)
 THEN RETURN jsonb_build_object('recorded',false,'code','INVALID_RESULT'); END IF;
 SELECT * INTO a FROM henvalt.shopify_pixel_send_attempts_v2 WHERE id=p_send_attempt_id FOR UPDATE;
 IF NOT FOUND THEN RETURN jsonb_build_object('recorded',false,'code','ATTEMPT_NOT_FOUND'); END IF;
 IF a.status<>'AUTHORIZED' THEN RETURN jsonb_build_object('recorded',false,'code','ATTEMPT_ALREADY_FINALIZED'); END IF;
 UPDATE henvalt.shopify_pixel_send_attempts_v2 SET status=p_status,provider_message_reference=p_provider_message_reference,updated_at=pg_catalog.now() WHERE id=a.id;
 RETURN jsonb_build_object('recorded',true,'status',p_status,'provider_cost_state',CASE WHEN p_status='SUBMITTED' THEN 'SETTLED' WHEN p_status='FAILED' THEN 'RELEASED' ELSE 'RESERVED' END);
END;$function$;

REVOKE ALL ON FUNCTION henvalt.issue_shopify_pixel_delivery_permit_v2(uuid,text,uuid,text) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION henvalt.consume_shopify_pixel_delivery_permit_v2(text) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION henvalt.record_shopify_pixel_send_attempt_result_v2(uuid,text,text) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION henvalt.issue_shopify_pixel_delivery_permit_v2(uuid,text,uuid,text) TO service_role;
GRANT EXECUTE ON FUNCTION henvalt.consume_shopify_pixel_delivery_permit_v2(text) TO service_role;
GRANT EXECUTE ON FUNCTION henvalt.record_shopify_pixel_send_attempt_result_v2(uuid,text,text) TO service_role;
COMMIT;

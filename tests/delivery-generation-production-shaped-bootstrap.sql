\set ON_ERROR_STOP on
CREATE EXTENSION IF NOT EXISTS pgcrypto;
CREATE ROLE anon NOLOGIN;
CREATE ROLE authenticated NOLOGIN;
CREATE ROLE service_role NOLOGIN;
CREATE SCHEMA auth;
CREATE SCHEMA henvalt;

CREATE OR REPLACE FUNCTION auth.role()
RETURNS text LANGUAGE sql STABLE AS $$
  SELECT current_setting('request.jwt.claim.role', true)
$$;


CREATE OR REPLACE FUNCTION henvalt.render_sender_identity_footer(p_tenant_id uuid,p_html text)
RETURNS text LANGUAGE sql IMMUTABLE AS $fn$ SELECT COALESCE(p_html,'') $fn$;
CREATE OR REPLACE FUNCTION henvalt.render_email_plain_text(p_html text)
RETURNS text LANGUAGE sql IMMUTABLE AS $fn$
  SELECT NULLIF(btrim(regexp_replace(COALESCE(p_html,''),'<[^>]*>',' ','g')),'')
$fn$;

CREATE TYPE henvalt.delivery_state AS ENUM ('PENDING','ACCEPTED','DELIVERED','FAILED','REJECTED','UNKNOWN');
CREATE TYPE henvalt.channel_type AS ENUM ('EMAIL','SMS');
CREATE TYPE henvalt.delivery_mode AS ENUM ('HENVALT_MANAGED','MERCHANT_MANAGED');
CREATE TYPE henvalt.intervention_status AS ENUM ('PENDING','SCHEDULED','READY','SENDING','SENT','DELIVERED','FAILED','SKIPPED','CANCELLED');
CREATE TYPE henvalt.job_status AS ENUM ('QUEUED','CLAIMED','RUNNING','RETRY_WAIT','SUCCEEDED','DEAD_LETTER');

CREATE TABLE henvalt.background_jobs (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id uuid,
  job_type text NOT NULL,
  payload jsonb NOT NULL DEFAULT '{}'::jsonb,
  status henvalt.job_status NOT NULL DEFAULT 'QUEUED',
  priority integer NOT NULL DEFAULT 100,
  attempts integer NOT NULL DEFAULT 0,
  max_attempts integer NOT NULL DEFAULT 5,
  run_at timestamptz NOT NULL DEFAULT now(),
  next_run_at timestamptz,
  locked_at timestamptz,
  locked_by text,
  last_error text,
  completed_at timestamptz,
  correlation_id uuid,
  idempotency_key text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE henvalt.messages (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id uuid NOT NULL,
  intervention_id uuid NOT NULL,
  channel henvalt.channel_type NOT NULL,
  recipient text NOT NULL,
  subject text,
  body text NOT NULL,
  tracking_token_id uuid,
  rendered_at timestamptz,
  metadata jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE henvalt.recovery_interventions (
  id uuid PRIMARY KEY,
  tenant_id uuid NOT NULL,
  opportunity_id uuid NOT NULL,
  channel henvalt.channel_type NOT NULL,
  status henvalt.intervention_status NOT NULL,
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE OR REPLACE FUNCTION henvalt.resolve_intervention_send_failure(
  p_intervention_id uuid,p_final_status henvalt.intervention_status,p_reason text
) RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER SET search_path=henvalt,pg_temp AS $fn$
DECLARE v_rows integer;
BEGIN
  UPDATE henvalt.recovery_interventions
     SET status=p_final_status,updated_at=now()
   WHERE id=p_intervention_id AND status='SENDING';
  GET DIAGNOSTICS v_rows=ROW_COUNT;
  IF v_rows=1 THEN RETURN true; END IF;
  RETURN EXISTS(SELECT 1 FROM henvalt.recovery_interventions WHERE id=p_intervention_id AND status=p_final_status);
END;
$fn$;

CREATE TABLE henvalt.delivery_requests (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id uuid NOT NULL,
  intervention_id uuid NOT NULL REFERENCES henvalt.recovery_interventions(id),
  recovery_id uuid,
  opportunity_id uuid,
  channel henvalt.channel_type NOT NULL,
  delivery_mode henvalt.delivery_mode NOT NULL,
  recipient_reference text NOT NULL,
  message_reference uuid,
  template_reference text,
  tracking_token text,
  scheduled_at timestamptz,
  status henvalt.delivery_state NOT NULL DEFAULT 'PENDING',
  provider text,
  provider_message_id text,
  idempotency_key text NOT NULL,
  correlation_id uuid NOT NULL DEFAULT gen_random_uuid(),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  provider_claimed_at timestamptz
);
CREATE UNIQUE INDEX ux_delivery_request_intervention
  ON henvalt.delivery_requests(tenant_id,intervention_id);
CREATE UNIQUE INDEX delivery_requests_tenant_id_idempotency_key_key
  ON henvalt.delivery_requests(tenant_id,idempotency_key);

CREATE TABLE henvalt.delivery_attempts (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id uuid NOT NULL,
  delivery_request_id uuid NOT NULL REFERENCES henvalt.delivery_requests(id),
  attempt_number integer NOT NULL,
  provider text,
  provider_message_id text,
  provider_status_code integer,
  state henvalt.delivery_state NOT NULL,
  error_class text,
  retryable boolean NOT NULL DEFAULT false,
  provider_response jsonb NOT NULL DEFAULT '{}'::jsonb,
  attempted_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE henvalt.email_usage_reservations (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id uuid NOT NULL,
  delivery_request_id uuid NOT NULL UNIQUE REFERENCES henvalt.delivery_requests(id),
  cycle_start timestamptz NOT NULL DEFAULT now(),
  status text NOT NULL CHECK(status IN ('RESERVED','CONSUMED','RELEASED')),
  status_reason text NOT NULL,
  last_attempt_id uuid,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE henvalt.email_usage_reservation_events (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  reservation_id uuid NOT NULL REFERENCES henvalt.email_usage_reservations(id),
  tenant_id uuid NOT NULL,
  delivery_request_id uuid NOT NULL,
  event_type text NOT NULL,
  previous_status text,
  new_status text NOT NULL,
  delivery_attempt_id uuid,
  reason text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE henvalt.provider_events (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  provider text NOT NULL,
  event_hash text NOT NULL,
  event_type text NOT NULL,
  provider_message_id text,
  recipient_email text,
  tenant_id uuid,
  delivery_request_id uuid,
  occurred_at timestamptz,
  payload jsonb NOT NULL DEFAULT '{}'::jsonb
);

-- Fields introduced by the quota-reservation candidate and used by
-- late-provider-acceptance reconciliation.
ALTER TABLE henvalt.email_usage_reservations
  ADD COLUMN consumed_at timestamptz,
  ADD COLUMN released_at timestamptz,
  ADD COLUMN updated_at timestamptz NOT NULL DEFAULT now();
ALTER TABLE henvalt.email_usage_reservation_events
  ADD COLUMN provider_status_code integer;

-- Minimal production interlock fixture required by the egress-fence migration.
CREATE TABLE henvalt.provider_send_control (
  control_key text PRIMARY KEY CHECK(control_key='global'),
  provider_sending_enabled boolean NOT NULL DEFAULT false
);
INSERT INTO henvalt.provider_send_control(control_key,provider_sending_enabled)
VALUES('global',true);
CREATE OR REPLACE FUNCTION henvalt.assert_provider_sending_enabled()
RETURNS void LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,henvalt,pg_temp AS $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM henvalt.provider_send_control
     WHERE control_key='global' AND provider_sending_enabled IS TRUE
  ) THEN
    RAISE EXCEPTION 'HENVALT_PROVIDER_SENDING_DISABLED' USING ERRCODE='42501';
  END IF;
END;
$$;
REVOKE ALL ON FUNCTION henvalt.assert_provider_sending_enabled()
  FROM PUBLIC,anon,authenticated,service_role;


-- Minimal production-shaped MailerSend webhook processor. Its lookup and
-- result-delegation anchors intentionally mirror the deployed function so
-- candidate source-preserving webhook patches are exercised by CI.
ALTER TABLE henvalt.provider_events ADD COLUMN processed_at timestamptz, ADD COLUMN processing_result jsonb NOT NULL DEFAULT '{}'::jsonb;

CREATE UNIQUE INDEX provider_events_provider_hash_uq
  ON henvalt.provider_events(provider,event_hash);

CREATE OR REPLACE FUNCTION henvalt.record_delivery_result(
  p_delivery_request_id uuid,p_provider text,p_provider_message_id text,
  p_provider_status_code integer,p_state henvalt.delivery_state,
  p_error_class text,p_retryable boolean,p_provider_response jsonb
) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path=henvalt,public AS $$
BEGIN
  UPDATE henvalt.delivery_requests
     SET provider_message_id=coalesce(provider_message_id,p_provider_message_id),
         status=p_state,updated_at=clock_timestamp()
   WHERE id=p_delivery_request_id;
  RETURN p_delivery_request_id;
END;
$$;

CREATE OR REPLACE FUNCTION henvalt.process_mailersend_webhook_event(
  p_payload jsonb,p_raw_body_base64 text
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=henvalt,extensions,pg_temp AS $$
DECLARE
  v_hash text;
  v_type text;
  v_data jsonb;
  v_mid text;
  v_email text;
  v_tenant uuid;
  v_req uuid;
  v_event uuid;
  v_time timestamptz;
BEGIN
  v_type := p_payload->>'type';
  v_data := coalesce(p_payload->'data','{}'::jsonb);
  v_mid := nullif(v_data->>'message_id','');
  v_email := lower(nullif(coalesce(v_data->>'email',v_data->>'recipient'),''));
  v_tenant := nullif(p_payload->>'tenant_id','')::uuid;
  v_hash := md5(p_raw_body_base64);
  IF jsonb_typeof(v_data->'tags') = 'array' THEN
    SELECT substring(t.tag from '^tenant:([0-9a-fA-F-]{36})$')::uuid
      INTO v_tenant
      FROM jsonb_array_elements_text(v_data->'tags') AS t(tag)
     WHERE t.tag ~* '^tenant:[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
     LIMIT 1;
  END IF;

  INSERT INTO henvalt.provider_events (
    provider,event_hash,event_type,provider_message_id,recipient_email,tenant_id,occurred_at,payload
  ) VALUES (
    'mailersend',v_hash,v_type,v_mid,v_email,v_tenant,now(),p_payload
  ) ON CONFLICT(provider,event_hash) DO NOTHING
  RETURNING id INTO v_event;
  IF v_event IS NULL THEN
    SELECT id INTO v_event FROM henvalt.provider_events
     WHERE provider='mailersend' AND event_hash=v_hash LIMIT 1;
    RETURN jsonb_build_object('accepted',true,'duplicate',true,'event_id',v_event);
  END IF;

  IF v_tenant IS NOT NULL AND v_mid IS NOT NULL THEN
    SELECT dr.id INTO v_req
      FROM henvalt.delivery_requests dr
     WHERE dr.tenant_id = v_tenant
       AND lower(COALESCE(dr.provider, '')) = 'mailersend'
       AND dr.provider_message_id = v_mid
     ORDER BY dr.created_at DESC
     LIMIT 1;

    IF v_req IS NULL THEN RAISE EXCEPTION 'Provider event is not yet linked to a delivery request'; END IF;
    UPDATE henvalt.provider_events
       SET delivery_request_id = v_req
     WHERE id = v_event;
  END IF;

  IF v_req IS NOT NULL AND v_type = 'activity.delivered' THEN
    PERFORM henvalt.record_delivery_result(v_req,'mailersend',v_mid,200,'DELIVERED'::henvalt.delivery_state,NULL,false,p_payload);
  END IF;
  UPDATE henvalt.provider_events SET processed_at=now() WHERE id=v_event;
  RETURN jsonb_build_object('accepted',true,'event_id',v_event,'matched_delivery_request',v_req IS NOT NULL);
END;
$$;

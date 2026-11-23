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

CREATE TYPE henvalt.delivery_state AS ENUM ('PENDING','ACCEPTED','DELIVERED','FAILED','REJECTED','UNKNOWN');
CREATE TYPE henvalt.channel_type AS ENUM ('EMAIL','SMS');
CREATE TYPE henvalt.delivery_mode AS ENUM ('HENVALT_MANAGED','MERCHANT_MANAGED');
CREATE TYPE henvalt.intervention_status AS ENUM ('PENDING','SCHEDULED','READY','SENDING','SENT','DELIVERED','FAILED','SKIPPED','CANCELLED');

CREATE TABLE henvalt.recovery_interventions (
  id uuid PRIMARY KEY,
  tenant_id uuid NOT NULL,
  opportunity_id uuid NOT NULL,
  channel henvalt.channel_type NOT NULL,
  status henvalt.intervention_status NOT NULL,
  updated_at timestamptz NOT NULL DEFAULT now()
);
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

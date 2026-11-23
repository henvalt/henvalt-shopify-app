\set ON_ERROR_STOP on
CREATE SCHEMA IF NOT EXISTS henvalt;
CREATE EXTENSION IF NOT EXISTS pgcrypto;
CREATE TYPE henvalt.delivery_state AS ENUM ('PENDING','UNKNOWN','ACCEPTED','DELIVERED','FAILED','REJECTED');
CREATE TABLE henvalt.billing_accounts (
 tenant_id uuid PRIMARY KEY,
 status text NOT NULL,
 test_mode boolean NOT NULL DEFAULT false,
 activated_at timestamptz,
 currency char(3) NOT NULL DEFAULT 'USD',
 usage_cap_amount numeric(18,2) NOT NULL DEFAULT 100000,
 monthly_email_limit integer NOT NULL
);
CREATE TABLE henvalt.billing_measurements (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 tenant_id uuid NOT NULL,
 currency char(3) NOT NULL,
 henvalt_fee numeric(18,4) NOT NULL,
 status text NOT NULL,
 created_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE henvalt.email_usage_measurements (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 tenant_id uuid NOT NULL,
 delivery_attempt_id uuid NOT NULL UNIQUE,
 created_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE henvalt.delivery_requests (
 id uuid PRIMARY KEY,
 tenant_id uuid NOT NULL,
 status henvalt.delivery_state NOT NULL DEFAULT 'PENDING'
);
CREATE TABLE henvalt.delivery_attempts (
 id uuid PRIMARY KEY,
 tenant_id uuid NOT NULL,
 delivery_request_id uuid NOT NULL,
 state henvalt.delivery_state NOT NULL,
 provider_status_code integer,
 attempted_at timestamptz NOT NULL DEFAULT now()
);
CREATE OR REPLACE FUNCTION henvalt.enforce_billing_entitlement_before_delivery()
RETURNS trigger LANGUAGE plpgsql AS $function$
BEGIN RETURN NEW; END;
$function$;
CREATE TRIGGER enforce_billing_entitlement_before_delivery
BEFORE UPDATE OF status ON henvalt.delivery_requests
FOR EACH ROW EXECUTE FUNCTION henvalt.enforce_billing_entitlement_before_delivery();
CREATE OR REPLACE FUNCTION henvalt.measure_email_usage_after_attempt()
RETURNS trigger LANGUAGE plpgsql AS $function$
BEGIN
 IF NEW.state::text IN ('ACCEPTED','DELIVERED','UNKNOWN') THEN
   INSERT INTO henvalt.email_usage_measurements(tenant_id,delivery_attempt_id,created_at)
   VALUES(NEW.tenant_id,NEW.id,NEW.attempted_at)
   ON CONFLICT(delivery_attempt_id) DO NOTHING;
 END IF;
 RETURN NEW;
END;
$function$;
CREATE TRIGGER measure_email_usage_after_attempt
AFTER INSERT ON henvalt.delivery_attempts
FOR EACH ROW EXECUTE FUNCTION henvalt.measure_email_usage_after_attempt();

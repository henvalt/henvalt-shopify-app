\set ON_ERROR_STOP on
DO $roles$
BEGIN
 IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='anon') THEN CREATE ROLE anon NOLOGIN; END IF;
 IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='authenticated') THEN CREATE ROLE authenticated NOLOGIN; END IF;
 IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='service_role') THEN CREATE ROLE service_role NOLOGIN; END IF;
END
$roles$;

CREATE SCHEMA henvalt;
CREATE TYPE henvalt.opportunity_type AS ENUM (
 'ABANDONED_CART','ABANDONED_CHECKOUT','PAYMENT_FAILURE','PAYMENT_DECLINED','BROWSE_ABANDONMENT'
);
CREATE TABLE henvalt.tenants (
 id uuid PRIMARY KEY,
 name text NOT NULL,
 status text NOT NULL,
 default_currency char(3)
);
CREATE TABLE henvalt.shopify_connections (
 id uuid PRIMARY KEY,
 tenant_id uuid NOT NULL REFERENCES henvalt.tenants(id),
 shop_domain text NOT NULL,
 active boolean NOT NULL DEFAULT true
);
CREATE TABLE henvalt.opportunities (
 id uuid PRIMARY KEY,
 tenant_id uuid NOT NULL REFERENCES henvalt.tenants(id),
 opportunity_type henvalt.opportunity_type NOT NULL,
 status text NOT NULL,
 value_at_risk numeric NOT NULL DEFAULT 0,
 currency char(3) NOT NULL,
 created_at timestamptz NOT NULL DEFAULT now(),
 updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE henvalt.recovery_interventions (
 id uuid PRIMARY KEY,
 tenant_id uuid NOT NULL,
 opportunity_id uuid NOT NULL,
 status text NOT NULL,
 sent_at timestamptz,
 delivered_at timestamptz,
 created_at timestamptz NOT NULL DEFAULT now(),
 updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE henvalt.order_attributions (
 id uuid PRIMARY KEY,
 tenant_id uuid NOT NULL,
 order_id uuid NOT NULL,
 opportunity_id uuid,
 attribution_confidence text NOT NULL,
 evaluated_at timestamptz NOT NULL
);
CREATE TABLE henvalt.revenue_ledger (
 id uuid PRIMARY KEY,
 tenant_id uuid NOT NULL,
 opportunity_id uuid,
 entry_type text NOT NULL,
 amount numeric NOT NULL,
 currency char(3) NOT NULL,
 billable boolean NOT NULL,
 attribution_confidence text,
 created_at timestamptz NOT NULL
);

CREATE FUNCTION henvalt.control_plane_dashboard_summary(text,timestamptz,timestamptz)
RETURNS jsonb LANGUAGE sql AS $function$ SELECT '{}'::jsonb $function$;
CREATE FUNCTION henvalt.control_plane_revenue_series(text,timestamptz,timestamptz,text DEFAULT 'day')
RETURNS jsonb LANGUAGE sql AS $function$ SELECT '{}'::jsonb $function$;

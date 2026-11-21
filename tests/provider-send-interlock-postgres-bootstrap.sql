\set ON_ERROR_STOP on

DO $bootstrap$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'anon') THEN
    CREATE ROLE anon NOLOGIN;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'authenticated') THEN
    CREATE ROLE authenticated NOLOGIN;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'service_role') THEN
    CREATE ROLE service_role NOLOGIN;
  END IF;
END
$bootstrap$;

CREATE SCHEMA henvalt;
CREATE TYPE henvalt.delivery_state AS ENUM ('PENDING', 'UNKNOWN', 'ACCEPTED', 'DELIVERED', 'FAILED');
CREATE TABLE henvalt.delivery_requests (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  status henvalt.delivery_state NOT NULL,
  provider_claimed_at timestamptz
);

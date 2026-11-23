\set ON_ERROR_STOP on
CREATE EXTENSION IF NOT EXISTS pgcrypto;
CREATE SCHEMA henvalt_test;

CREATE TABLE henvalt_test.interventions (
  id uuid PRIMARY KEY,
  tenant_id uuid NOT NULL,
  frozen_at timestamptz,
  freeze_reason text,
  consent_ok boolean NOT NULL DEFAULT true,
  interlock_open boolean NOT NULL DEFAULT true,
  tenant_active boolean NOT NULL DEFAULT true
);

CREATE TABLE henvalt_test.delivery_requests (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id uuid NOT NULL,
  intervention_id uuid NOT NULL REFERENCES henvalt_test.interventions(id),
  recipient_email text NOT NULL DEFAULT 'recipient@example.test',
  provider_message_id text,
  generation_number integer NOT NULL CHECK (generation_number > 0),
  status text NOT NULL CHECK (status IN ('PENDING','UNKNOWN','ACCEPTED','DELIVERED','FAILED','REJECTED')),
  idempotency_key text NOT NULL,
  provider_egress_started_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (tenant_id, idempotency_key),
  UNIQUE (tenant_id, intervention_id, generation_number)
);

CREATE TABLE henvalt_test.delivery_attempts (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  delivery_request_id uuid NOT NULL REFERENCES henvalt_test.delivery_requests(id),
  attempt_number integer NOT NULL CHECK (attempt_number > 0),
  state text NOT NULL,
  stage text NOT NULL CHECK (stage IN ('pre_provider','provider_response','provider_event')),
  provider_status_code integer,
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (delivery_request_id, attempt_number)
);

CREATE TABLE henvalt_test.reservations (
  delivery_request_id uuid PRIMARY KEY REFERENCES henvalt_test.delivery_requests(id),
  status text NOT NULL CHECK (status IN ('RESERVED','RELEASED','CONSUMED')),
  reason text NOT NULL
);

CREATE TABLE henvalt_test.retry_commands (
  tenant_id uuid NOT NULL,
  intervention_id uuid NOT NULL REFERENCES henvalt_test.interventions(id),
  retry_command_id uuid NOT NULL,
  generation_number integer NOT NULL,
  delivery_request_id uuid NOT NULL UNIQUE REFERENCES henvalt_test.delivery_requests(id),
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (tenant_id, intervention_id, retry_command_id),
  UNIQUE (tenant_id, intervention_id, generation_number)
);

CREATE TABLE henvalt_test.provider_events (
  event_id text PRIMARY KEY,
  delivery_request_id uuid NOT NULL REFERENCES henvalt_test.delivery_requests(id),
  provider_message_id text,
  event_type text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE henvalt_test.incidents (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  intervention_id uuid NOT NULL REFERENCES henvalt_test.interventions(id),
  delivery_request_id uuid NOT NULL REFERENCES henvalt_test.delivery_requests(id),
  incident_type text NOT NULL,
  provider_event_id text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (provider_event_id)
);

CREATE OR REPLACE FUNCTION henvalt_test.seed_initial(p_intervention_id uuid)
RETURNS uuid LANGUAGE plpgsql AS $$
DECLARE v_tenant uuid; v_request uuid;
BEGIN
  INSERT INTO henvalt_test.interventions(id,tenant_id)
  VALUES(p_intervention_id,gen_random_uuid());
  SELECT tenant_id INTO v_tenant FROM henvalt_test.interventions WHERE id=p_intervention_id;
  INSERT INTO henvalt_test.delivery_requests(tenant_id,intervention_id,generation_number,status,idempotency_key)
  VALUES(v_tenant,p_intervention_id,1,'PENDING','deliver:'||p_intervention_id||':g1')
  RETURNING id INTO v_request;
  INSERT INTO henvalt_test.reservations(delivery_request_id,status,reason)
  VALUES(v_request,'RESERVED','DELIVERY_CLAIMED');
  RETURN v_request;
END $$;

CREATE OR REPLACE FUNCTION henvalt_test.mark_pre_provider_failure(p_request uuid)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  UPDATE henvalt_test.delivery_requests SET status='FAILED' WHERE id=p_request;
  INSERT INTO henvalt_test.delivery_attempts(delivery_request_id,attempt_number,state,stage,provider_status_code)
  VALUES(p_request,1,'FAILED','pre_provider',409);
  UPDATE henvalt_test.reservations SET status='RELEASED',reason='SERVER_PROVEN_PRE_PROVIDER'
   WHERE delivery_request_id=p_request;
END $$;

CREATE OR REPLACE FUNCTION henvalt_test.mark_ambiguous(p_request uuid)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  UPDATE henvalt_test.delivery_requests SET status='UNKNOWN' WHERE id=p_request;
  INSERT INTO henvalt_test.delivery_attempts(delivery_request_id,attempt_number,state,stage,provider_status_code)
  VALUES(p_request,1,'UNKNOWN','provider_response',503);
  UPDATE henvalt_test.reservations SET status='CONSUMED',reason='PROVIDER_OUTCOME_AMBIGUOUS'
   WHERE delivery_request_id=p_request;
END $$;

CREATE OR REPLACE FUNCTION henvalt_test.create_retry_generation(
  p_intervention_id uuid, p_retry_command_id uuid
) RETURNS uuid LANGUAGE plpgsql AS $$
DECLARE
  v_tenant uuid;
  v_existing uuid;
  v_previous henvalt_test.delivery_requests%ROWTYPE;
  v_attempt henvalt_test.delivery_attempts%ROWTYPE;
  v_reservation henvalt_test.reservations%ROWTYPE;
  v_next integer;
  v_new uuid;
BEGIN
  -- Canonical lock order: parent -> request -> reservation -> attempt/evidence.
  SELECT tenant_id INTO v_tenant
    FROM henvalt_test.interventions
   WHERE id=p_intervention_id
   FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'INTERVENTION_NOT_FOUND'; END IF;

  SELECT delivery_request_id INTO v_existing
    FROM henvalt_test.retry_commands
   WHERE tenant_id=v_tenant AND intervention_id=p_intervention_id
     AND retry_command_id=p_retry_command_id;
  IF FOUND THEN RETURN v_existing; END IF;

  IF EXISTS (SELECT 1 FROM henvalt_test.interventions
              WHERE id=p_intervention_id AND frozen_at IS NOT NULL) THEN
    RAISE EXCEPTION 'INTERVENTION_FROZEN';
  END IF;

  SELECT * INTO v_previous
    FROM henvalt_test.delivery_requests
   WHERE tenant_id=v_tenant AND intervention_id=p_intervention_id
   ORDER BY generation_number DESC LIMIT 1
   FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'INITIAL_GENERATION_REQUIRED'; END IF;

  SELECT * INTO v_attempt
    FROM henvalt_test.delivery_attempts
   WHERE delivery_request_id=v_previous.id
   ORDER BY attempt_number DESC LIMIT 1;
  SELECT * INTO v_reservation
    FROM henvalt_test.reservations
   WHERE delivery_request_id=v_previous.id
   FOR UPDATE;

  IF v_previous.status <> 'FAILED'
     OR v_previous.provider_egress_started_at IS NOT NULL
     OR v_attempt.id IS NULL
     OR v_attempt.state <> 'FAILED'
     OR v_attempt.stage <> 'pre_provider'
     OR v_reservation.delivery_request_id IS NULL
     OR v_reservation.status <> 'RELEASED'
     OR EXISTS (SELECT 1 FROM henvalt_test.provider_events
                 WHERE delivery_request_id=v_previous.id
                   AND event_type IN ('accepted','delivered')) THEN
    RAISE EXCEPTION 'PREVIOUS_GENERATION_NOT_PROVEN_RETRYABLE';
  END IF;

  v_next := v_previous.generation_number + 1;
  INSERT INTO henvalt_test.delivery_requests(
    tenant_id,intervention_id,generation_number,status,idempotency_key
  ) VALUES (
    v_tenant,p_intervention_id,v_next,'PENDING',
    'deliver:'||p_intervention_id||':g'||v_next
  ) RETURNING id INTO v_new;

  INSERT INTO henvalt_test.reservations(delivery_request_id,status,reason)
  VALUES(v_new,'RESERVED','DELIVERY_CLAIMED');

  INSERT INTO henvalt_test.retry_commands(
    tenant_id,intervention_id,retry_command_id,generation_number,delivery_request_id
  ) VALUES(v_tenant,p_intervention_id,p_retry_command_id,v_next,v_new);

  RETURN v_new;
END $$;

CREATE OR REPLACE FUNCTION henvalt_test.claim_generation(p_request uuid)
RETURNS boolean LANGUAGE plpgsql AS $$
DECLARE v_parent uuid; v_gen integer; v_latest integer; v_status text;
BEGIN
  SELECT intervention_id INTO v_parent
    FROM henvalt_test.delivery_requests WHERE id=p_request;
  IF NOT FOUND THEN RETURN false; END IF;
  PERFORM 1 FROM henvalt_test.interventions WHERE id=v_parent FOR UPDATE;
  SELECT generation_number,status INTO v_gen,v_status
    FROM henvalt_test.delivery_requests WHERE id=p_request FOR UPDATE;
  SELECT max(generation_number) INTO v_latest
    FROM henvalt_test.delivery_requests WHERE intervention_id=v_parent;
  IF v_gen<>v_latest OR v_status<>'PENDING' THEN RETURN false; END IF;
  IF EXISTS (SELECT 1 FROM henvalt_test.interventions
              WHERE id=v_parent AND (frozen_at IS NOT NULL OR NOT consent_ok OR NOT interlock_open OR NOT tenant_active)) THEN
    RETURN false;
  END IF;
  UPDATE henvalt_test.delivery_requests SET status='UNKNOWN' WHERE id=p_request;
  RETURN true;
END $$;

CREATE OR REPLACE FUNCTION henvalt_test.start_provider_egress(p_request uuid)
RETURNS boolean LANGUAGE plpgsql AS $$
DECLARE v_parent uuid; v_gen integer; v_latest integer; v_status text; v_started timestamptz;
BEGIN
  SELECT intervention_id INTO v_parent FROM henvalt_test.delivery_requests WHERE id=p_request;
  IF NOT FOUND THEN RETURN false; END IF;
  PERFORM 1 FROM henvalt_test.interventions WHERE id=v_parent FOR UPDATE;
  SELECT generation_number,status,provider_egress_started_at
    INTO v_gen,v_status,v_started
    FROM henvalt_test.delivery_requests WHERE id=p_request FOR UPDATE;
  SELECT max(generation_number) INTO v_latest FROM henvalt_test.delivery_requests WHERE intervention_id=v_parent;
  IF v_gen<>v_latest OR v_status<>'UNKNOWN' OR v_started IS NOT NULL THEN RETURN false; END IF;
  IF EXISTS (SELECT 1 FROM henvalt_test.interventions
              WHERE id=v_parent AND (frozen_at IS NOT NULL OR NOT consent_ok OR NOT interlock_open OR NOT tenant_active)) THEN
    RETURN false;
  END IF;
  UPDATE henvalt_test.delivery_requests
     SET provider_egress_started_at=clock_timestamp()
   WHERE id=p_request;
  RETURN true;
END $$;


CREATE OR REPLACE FUNCTION henvalt_test.resolve_delivery_tag(
  p_tags text[], p_recipient text, p_message_id text
) RETURNS uuid LANGUAGE plpgsql AS $$
DECLARE
  v_tenant_count integer;
  v_delivery_count integer;
  v_tenant uuid;
  v_request_id uuid;
  v_parent uuid;
  v_request henvalt_test.delivery_requests%ROWTYPE;
BEGIN
  SELECT count(*) FILTER (WHERE tag ~* '^tenant:[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'),
         count(*) FILTER (WHERE tag ~* '^delivery:[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$')
    INTO v_tenant_count,v_delivery_count
    FROM unnest(coalesce(p_tags,ARRAY[]::text[])) AS tags(tag);
  IF v_tenant_count<>1 OR v_delivery_count<>1 THEN
    RAISE EXCEPTION 'EXACT_TENANT_AND_DELIVERY_TAG_REQUIRED';
  END IF;

  SELECT substring(tag from '^tenant:([0-9a-fA-F-]{36})$')::uuid
    INTO v_tenant
    FROM unnest(p_tags) AS tags(tag)
   WHERE tag ~* '^tenant:[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$';
  SELECT substring(tag from '^delivery:([0-9a-fA-F-]{36})$')::uuid
    INTO v_request_id
    FROM unnest(p_tags) AS tags(tag)
   WHERE tag ~* '^delivery:[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$';

  SELECT intervention_id INTO v_parent
    FROM henvalt_test.delivery_requests
   WHERE id=v_request_id AND tenant_id=v_tenant;
  IF NOT FOUND THEN RAISE EXCEPTION 'DELIVERY_TAG_NOT_FOUND_FOR_TENANT'; END IF;
  PERFORM 1 FROM henvalt_test.interventions WHERE id=v_parent FOR UPDATE;
  SELECT * INTO v_request
    FROM henvalt_test.delivery_requests
   WHERE id=v_request_id AND tenant_id=v_tenant
   FOR UPDATE;
  IF lower(v_request.recipient_email)<>lower(coalesce(p_recipient,'')) THEN
    RAISE EXCEPTION 'PROVIDER_RECIPIENT_MISMATCH';
  END IF;
  IF v_request.provider_message_id IS NOT NULL
     AND v_request.provider_message_id IS DISTINCT FROM p_message_id THEN
    RAISE EXCEPTION 'PROVIDER_MESSAGE_ID_MISMATCH';
  END IF;
  IF p_message_id IS NOT NULL AND EXISTS (
    SELECT 1 FROM henvalt_test.delivery_requests
     WHERE tenant_id=v_tenant AND provider_message_id=p_message_id AND id<>v_request_id
  ) THEN
    RAISE EXCEPTION 'PROVIDER_MESSAGE_ID_ALREADY_BOUND';
  END IF;
  RETURN v_request_id;
END $$;

CREATE OR REPLACE FUNCTION henvalt_test.settle_late_acceptance(
  p_event_id text, p_request uuid, p_message_id text
) RETURNS boolean LANGUAGE plpgsql AS $$
DECLARE v_parent uuid; v_tenant uuid; v_status text; v_gen integer; v_latest integer; v_inserted text;
        v_existing_request uuid; v_existing_message_id text; v_request_message_id text;
BEGIN
  SELECT intervention_id,tenant_id,provider_message_id INTO v_parent,v_tenant,v_request_message_id
    FROM henvalt_test.delivery_requests WHERE id=p_request;
  IF NOT FOUND THEN RAISE EXCEPTION 'DELIVERY_REQUEST_NOT_FOUND'; END IF;
  PERFORM 1 FROM henvalt_test.interventions WHERE id=v_parent FOR UPDATE;
  PERFORM 1 FROM henvalt_test.delivery_requests WHERE id=p_request AND tenant_id=v_tenant FOR UPDATE;

  INSERT INTO henvalt_test.provider_events(event_id,delivery_request_id,provider_message_id,event_type)
  VALUES(p_event_id,p_request,p_message_id,'delivered')
  ON CONFLICT(event_id) DO NOTHING
  RETURNING event_id INTO v_inserted;
  IF v_inserted IS NULL THEN
    SELECT delivery_request_id,provider_message_id INTO v_existing_request,v_existing_message_id
      FROM henvalt_test.provider_events WHERE event_id=p_event_id;
    IF v_existing_request IS DISTINCT FROM p_request
       OR v_existing_message_id IS DISTINCT FROM p_message_id THEN
      RAISE EXCEPTION 'PROVIDER_EVENT_IDENTITY_CONFLICT';
    END IF;
    RETURN false;
  END IF;

  IF v_request_message_id IS NOT NULL AND v_request_message_id IS DISTINCT FROM p_message_id THEN
    RAISE EXCEPTION 'PROVIDER_MESSAGE_ID_MISMATCH';
  END IF;
  IF EXISTS (SELECT 1 FROM henvalt_test.delivery_requests
              WHERE tenant_id=v_tenant AND provider_message_id=p_message_id AND id<>p_request) THEN
    RAISE EXCEPTION 'PROVIDER_MESSAGE_ID_ALREADY_BOUND';
  END IF;
  UPDATE henvalt_test.delivery_requests SET provider_message_id=p_message_id WHERE id=p_request;

  SELECT status,generation_number INTO v_status,v_gen
    FROM henvalt_test.delivery_requests WHERE id=p_request;
  SELECT max(generation_number) INTO v_latest
    FROM henvalt_test.delivery_requests WHERE intervention_id=v_parent;

  UPDATE henvalt_test.reservations SET status='CONSUMED',reason='LATE_PROVIDER_ACCEPTANCE'
   WHERE delivery_request_id=p_request AND status IN ('RELEASED','RESERVED');

  INSERT INTO henvalt_test.delivery_attempts(delivery_request_id,attempt_number,state,stage,provider_status_code)
  SELECT p_request,coalesce(max(attempt_number),0)+1,'ACCEPTED','provider_event',200
    FROM henvalt_test.delivery_attempts WHERE delivery_request_id=p_request;

  IF v_status='FAILED' OR v_gen<v_latest THEN
    UPDATE henvalt_test.interventions
       SET frozen_at=coalesce(frozen_at,clock_timestamp()),
           freeze_reason='CONTRADICTORY_LATE_ACCEPTANCE'
     WHERE id=v_parent;
    INSERT INTO henvalt_test.incidents(intervention_id,delivery_request_id,incident_type,provider_event_id)
    VALUES(v_parent,p_request,'CONTRADICTORY_LATE_ACCEPTANCE',p_event_id)
    ON CONFLICT(provider_event_id) DO NOTHING;
  ELSE
    UPDATE henvalt_test.delivery_requests SET status='DELIVERED' WHERE id=p_request;
  END IF;
  RETURN true;
END $$;

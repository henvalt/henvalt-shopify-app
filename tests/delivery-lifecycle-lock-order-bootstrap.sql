\set ON_ERROR_STOP on
CREATE ROLE anon NOLOGIN;
CREATE ROLE authenticated NOLOGIN;
CREATE ROLE service_role NOLOGIN;
CREATE SCHEMA henvalt;
CREATE TYPE henvalt.delivery_state AS ENUM ('PENDING','UNKNOWN','DELIVERED','FAILED','REJECTED');
CREATE TABLE henvalt.recovery_interventions (
  id uuid PRIMARY KEY,
  tenant_id uuid NOT NULL
);
CREATE TABLE henvalt.delivery_requests (
  id uuid PRIMARY KEY,
  tenant_id uuid NOT NULL,
  intervention_id uuid NOT NULL REFERENCES henvalt.recovery_interventions(id),
  status henvalt.delivery_state NOT NULL DEFAULT 'PENDING',
  provider text,
  provider_message_id text,
  provider_claimed_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE OR REPLACE FUNCTION henvalt.authorize_delivery_request(
  p_tenant_id uuid,p_delivery_request_id uuid,p_intervention_id uuid,
  p_recovery_id uuid,p_opportunity_id uuid,p_recipient text,p_idempotency_key text
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=henvalt,pg_temp AS $$
DECLARE v_request henvalt.delivery_requests%ROWTYPE;
BEGIN
  SELECT * INTO v_request FROM henvalt.delivery_requests
  WHERE id = p_delivery_request_id AND tenant_id = p_tenant_id FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('can_send',false); END IF;
  IF v_request.intervention_id <> p_intervention_id THEN RETURN jsonb_build_object('can_send',false); END IF;
  RETURN jsonb_build_object('can_send',true);
END;
$$;

CREATE OR REPLACE FUNCTION henvalt.get_mailersend_token_for_delivery(
  p_tenant_id uuid,p_delivery_request_id uuid
) RETURNS text LANGUAGE plpgsql SECURITY DEFINER SET search_path=henvalt,pg_temp AS $$
BEGIN
  UPDATE henvalt.delivery_requests dr
     SET provider_claimed_at = clock_timestamp(),
         updated_at = now()
   WHERE dr.id = p_delivery_request_id
     AND dr.tenant_id = p_tenant_id
     AND dr.status = 'UNKNOWN';
  RETURN CASE WHEN FOUND THEN 'token' ELSE NULL END;
END;
$$;

CREATE OR REPLACE FUNCTION henvalt.record_delivery_result(
  p_delivery_request_id uuid,p_provider text,p_provider_message_id text,
  p_provider_status_code integer,p_state henvalt.delivery_state,
  p_error_class text,p_retryable boolean,p_provider_response jsonb
) RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path=henvalt,pg_temp AS $$
DECLARE v_tenant_id uuid; v_intervention_id uuid; v_current_state henvalt.delivery_state;
BEGIN
  IF p_state IS NULL THEN RAISE EXCEPTION 'Delivery state is required'; END IF;
  SELECT
    tenant_id,
    intervention_id,
    status
  INTO
    v_tenant_id,
    v_intervention_id,
    v_current_state
  FROM henvalt.delivery_requests
  WHERE id = p_delivery_request_id
  FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Delivery request not found: %',p_delivery_request_id; END IF;
  RETURN p_delivery_request_id;
END;
$$;

CREATE OR REPLACE FUNCTION henvalt.process_mailersend_webhook_event(
  p_payload jsonb,p_raw_body_base64 text
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=henvalt,pg_temp AS $$
DECLARE v_req uuid;
BEGIN
  SELECT dr.id INTO v_req
    FROM henvalt.delivery_requests dr
   WHERE dr.tenant_id = (p_payload->>'tenant_id')::uuid
     AND lower(COALESCE(dr.provider, '')) = 'mailersend'
     AND dr.provider_message_id = p_payload->>'message_id'
   ORDER BY dr.created_at DESC
   LIMIT 1
   FOR UPDATE;
  RETURN jsonb_build_object('matched',v_req IS NOT NULL);
END;
$$;

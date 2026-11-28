-- Durable handling for MailerSend acceptance evidence that arrives after a
-- delivery generation failed or a newer generation already exists.
-- Candidate only; requires migrations 001-005 and coordinated webhook routing.
BEGIN;

CREATE UNIQUE INDEX IF NOT EXISTS ux_delivery_generation_incident_provider_event
  ON henvalt.delivery_generation_incidents(provider_event_id)
  WHERE provider_event_id IS NOT NULL;

CREATE OR REPLACE FUNCTION henvalt.settle_late_provider_acceptance(
  p_provider_event_id uuid
) RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO pg_catalog, henvalt, pg_temp
AS $function$
DECLARE
  v_event henvalt.provider_events%ROWTYPE;
  v_parent_id uuid;
  v_request henvalt.delivery_requests%ROWTYPE;
  v_latest_generation integer;
  v_tenant_tag_count integer := 0;
  v_delivery_tag_count integer := 0;
  v_tenant_prefix_count integer := 0;
  v_delivery_prefix_count integer := 0;
  v_tag_tenant uuid;
  v_tag_request uuid;
  v_reservation henvalt.email_usage_reservations%ROWTYPE;
  v_existing henvalt.delivery_generation_incidents%ROWTYPE;
BEGIN
  IF auth.role() IS DISTINCT FROM 'service_role' THEN
    RAISE EXCEPTION 'SERVICE_ROLE_REQUIRED' USING ERRCODE = '42501';
  END IF;
  IF p_provider_event_id IS NULL THEN
    RAISE EXCEPTION 'PROVIDER_EVENT_ID_REQUIRED' USING ERRCODE = '22023';
  END IF;

  SELECT * INTO v_event
    FROM henvalt.provider_events
   WHERE id = p_provider_event_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'PROVIDER_EVENT_NOT_FOUND'; END IF;
  IF v_event.provider <> 'mailersend'
     OR v_event.event_type NOT IN ('activity.sent','activity.delivered')
     OR v_event.delivery_request_id IS NULL
     OR v_event.tenant_id IS NULL
     OR NULLIF(v_event.provider_message_id,'') IS NULL THEN
    RAISE EXCEPTION 'PROVIDER_ACCEPTANCE_EVENT_IDENTITY_INCOMPLETE';
  END IF;

  SELECT
    count(*) FILTER (WHERE tag ~* '^tenant:[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'),
    count(*) FILTER (WHERE tag ~* '^delivery:[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'),
    count(*) FILTER (WHERE lower(tag) LIKE 'tenant:%'),
    count(*) FILTER (WHERE lower(tag) LIKE 'delivery:%')
    INTO v_tenant_tag_count,v_delivery_tag_count,v_tenant_prefix_count,v_delivery_prefix_count
    FROM jsonb_array_elements_text(
      CASE WHEN jsonb_typeof(v_event.payload #> '{data,tags}')='array'
        THEN v_event.payload #> '{data,tags}' ELSE '[]'::jsonb END
    ) AS x(tag);
  IF v_tenant_tag_count <> 1 OR v_delivery_tag_count <> 1
     OR v_tenant_prefix_count <> 1 OR v_delivery_prefix_count <> 1 THEN
    RAISE EXCEPTION 'EXACT_TENANT_AND_DELIVERY_TAG_REQUIRED';
  END IF;

  SELECT substring(tag from '^tenant:([0-9a-fA-F-]{36})$')::uuid
    INTO v_tag_tenant
    FROM jsonb_array_elements_text(v_event.payload #> '{data,tags}') AS x(tag)
   WHERE tag ~* '^tenant:[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$';
  SELECT substring(tag from '^delivery:([0-9a-fA-F-]{36})$')::uuid
    INTO v_tag_request
    FROM jsonb_array_elements_text(v_event.payload #> '{data,tags}') AS x(tag)
   WHERE tag ~* '^delivery:[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$';

  IF v_tag_tenant IS DISTINCT FROM v_event.tenant_id
     OR v_tag_request IS DISTINCT FROM v_event.delivery_request_id THEN
    RAISE EXCEPTION 'PROVIDER_EVENT_TAG_IDENTITY_CONFLICT';
  END IF;

  -- Read the parent key without locking the child. Every lifecycle writer
  -- then follows the canonical parent -> request lock order.
  SELECT intervention_id INTO v_parent_id
    FROM henvalt.delivery_requests
   WHERE id = v_event.delivery_request_id
     AND tenant_id = v_event.tenant_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'DELIVERY_REQUEST_NOT_FOUND_FOR_PROVIDER_EVENT'; END IF;

  PERFORM 1 FROM henvalt.recovery_interventions
   WHERE id = v_parent_id AND tenant_id = v_event.tenant_id
   FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'DELIVERY_INTERVENTION_NOT_FOUND'; END IF;

  SELECT * INTO v_request
    FROM henvalt.delivery_requests
   WHERE id = v_event.delivery_request_id
     AND tenant_id = v_event.tenant_id
   FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'DELIVERY_REQUEST_NOT_FOUND_FOR_PROVIDER_EVENT'; END IF;
  IF lower(coalesce(v_request.provider,'')) <> 'mailersend' THEN
    RAISE EXCEPTION 'DELIVERY_PROVIDER_MISMATCH';
  END IF;
  IF v_request.provider_message_id IS NOT NULL
     AND v_request.provider_message_id IS DISTINCT FROM v_event.provider_message_id THEN
    RAISE EXCEPTION 'PROVIDER_MESSAGE_ID_MISMATCH';
  END IF;
  IF EXISTS (
    SELECT 1 FROM henvalt.delivery_requests
     WHERE tenant_id=v_event.tenant_id
       AND lower(coalesce(provider,''))='mailersend'
       AND provider_message_id=v_event.provider_message_id
       AND id<>v_request.id
  ) THEN
    RAISE EXCEPTION 'PROVIDER_MESSAGE_ID_ALREADY_BOUND';
  END IF;

  IF v_request.provider_message_id IS NULL THEN
    UPDATE henvalt.delivery_requests
       SET provider_message_id=v_event.provider_message_id,
           updated_at=clock_timestamp()
     WHERE id=v_request.id AND tenant_id=v_event.tenant_id;
  END IF;

  SELECT max(generation_number) INTO v_latest_generation
    FROM henvalt.delivery_requests
   WHERE tenant_id=v_event.tenant_id
     AND intervention_id=v_parent_id;

  IF v_request.status NOT IN ('FAILED','REJECTED')
     AND v_request.generation_number >= coalesce(v_latest_generation,v_request.generation_number) THEN
    RETURN false;
  END IF;

  UPDATE henvalt.recovery_interventions
     SET delivery_frozen_at=coalesce(delivery_frozen_at,clock_timestamp()),
         delivery_freeze_reason=coalesce(delivery_freeze_reason,'LATE_PROVIDER_ACCEPTANCE'),
         updated_at=clock_timestamp()
   WHERE id=v_parent_id AND tenant_id=v_event.tenant_id;

  INSERT INTO henvalt.delivery_generation_incidents(
    tenant_id,intervention_id,delivery_request_id,provider_event_id,incident_type,details
  ) VALUES (
    v_event.tenant_id,v_parent_id,v_request.id,v_event.id,'LATE_PROVIDER_ACCEPTANCE',
    jsonb_build_object(
      'event_type',v_event.event_type,
      'provider_message_id',v_event.provider_message_id,
      'request_status',v_request.status,
      'request_generation',v_request.generation_number,
      'latest_generation',v_latest_generation,
      'historical_attempts_preserved',true
    )
  ) ON CONFLICT (provider_event_id) WHERE provider_event_id IS NOT NULL DO NOTHING;

  SELECT * INTO v_existing
    FROM henvalt.delivery_generation_incidents
   WHERE provider_event_id=v_event.id;
  IF NOT FOUND
     OR v_existing.tenant_id IS DISTINCT FROM v_event.tenant_id
     OR v_existing.intervention_id IS DISTINCT FROM v_parent_id
     OR v_existing.delivery_request_id IS DISTINCT FROM v_request.id
     OR v_existing.incident_type <> 'LATE_PROVIDER_ACCEPTANCE' THEN
    RAISE EXCEPTION 'PROVIDER_EVENT_INCIDENT_IDENTITY_CONFLICT';
  END IF;

  -- Late provider evidence wins over a prior quota release. Preserve all
  -- attempts as recorded; append a reservation transition with no fabricated
  -- delivery_attempt_id because this is provider-event evidence, not a send.
  SELECT * INTO v_reservation
    FROM henvalt.email_usage_reservations
   WHERE tenant_id=v_event.tenant_id
     AND delivery_request_id=v_request.id
     AND status IN ('RESERVED','RELEASED')
   FOR UPDATE;
  IF FOUND THEN
    UPDATE henvalt.email_usage_reservations
       SET status='CONSUMED',
           status_reason='LATE_PROVIDER_ACCEPTANCE',
           consumed_at=coalesce(consumed_at,clock_timestamp()),
           released_at=NULL,
           updated_at=clock_timestamp()
     WHERE id=v_reservation.id;

    INSERT INTO henvalt.email_usage_reservation_events(
      reservation_id,tenant_id,delivery_request_id,event_type,
      previous_status,new_status,delivery_attempt_id,provider_status_code,reason
    ) VALUES (
      v_reservation.id,v_event.tenant_id,v_request.id,'CONSUMED',
      v_reservation.status,'CONSUMED',NULL,200,'LATE_PROVIDER_ACCEPTANCE'
    );
  END IF;

  RETURN true;
END;
$function$;

REVOKE ALL ON FUNCTION henvalt.settle_late_provider_acceptance(uuid)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION henvalt.settle_late_provider_acceptance(uuid)
  TO service_role;

COMMENT ON FUNCTION henvalt.settle_late_provider_acceptance(uuid) IS
  'Service-role-only idempotent late MailerSend acceptance handler. Locks intervention before request, validates exact tenant/delivery tags and message identity, freezes contradictory generations, records append-only incident evidence, consumes released quota, and never rewrites historical delivery attempts.';

COMMIT;

-- HENVALT consent revocation cascade across Shopify, HENVALT unsubscribe links, and MailerSend suppression events.

CREATE OR REPLACE FUNCTION henvalt.suppress_customer_recovery(p_tenant_id uuid, p_customer_id uuid, p_reason text DEFAULT 'email_consent_revoked'::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'henvalt', 'pg_temp'
AS $function$
DECLARE
  v_suppressed_opportunities integer := 0;
  v_cancelled_sequences integer := 0;
  v_cancelled_interventions integer := 0;
  v_rejected_deliveries integer := 0;
BEGIN
  IF p_tenant_id IS NULL OR p_customer_id IS NULL THEN
    RAISE EXCEPTION 'TENANT_AND_CUSTOMER_REQUIRED' USING ERRCODE = '22023';
  END IF;

  UPDATE henvalt.opportunities o
     SET status = 'SUPPRESSED',
         updated_at = now()
   WHERE o.tenant_id = p_tenant_id
     AND o.customer_id = p_customer_id
     AND o.status IN ('DETECTED', 'ELIGIBLE');
  GET DIAGNOSTICS v_suppressed_opportunities = ROW_COUNT;

  UPDATE henvalt.delivery_requests dr
     SET status = 'REJECTED',
         updated_at = now()
   WHERE dr.tenant_id = p_tenant_id
     AND dr.status = 'PENDING'
     AND EXISTS (
       SELECT 1 FROM henvalt.opportunities o
        WHERE o.id = dr.opportunity_id
          AND o.tenant_id = dr.tenant_id
          AND o.customer_id = p_customer_id
     );
  GET DIAGNOSTICS v_rejected_deliveries = ROW_COUNT;

  UPDATE henvalt.recovery_interventions ri
     SET status = 'CANCELLED',
         cancelled_at = COALESCE(ri.cancelled_at, now()),
         updated_at = now()
   WHERE ri.tenant_id = p_tenant_id
     AND ri.status IN ('PENDING', 'SCHEDULED', 'READY')
     AND EXISTS (
       SELECT 1 FROM henvalt.opportunities o
        WHERE o.id = ri.opportunity_id
          AND o.tenant_id = ri.tenant_id
          AND o.customer_id = p_customer_id
     );
  GET DIAGNOSTICS v_cancelled_interventions = ROW_COUNT;

  UPDATE henvalt.recovery_sequences rs
     SET status = 'CANCELLED',
         ended_at = COALESCE(rs.ended_at, now()),
         updated_at = now()
   WHERE rs.tenant_id = p_tenant_id
     AND rs.status IN ('SCHEDULED', 'ACTIVE', 'PAUSED')
     AND EXISTS (
       SELECT 1 FROM henvalt.opportunities o
        WHERE o.id = rs.opportunity_id
          AND o.tenant_id = rs.tenant_id
          AND o.customer_id = p_customer_id
     );
  GET DIAGNOSTICS v_cancelled_sequences = ROW_COUNT;

  INSERT INTO henvalt.audit_log (
    tenant_id, event_name, entity_type, entity_id, actor_type, actor_reference, payload
  ) VALUES (
    p_tenant_id, 'customer_recovery_suppressed', 'customer', p_customer_id,
    'system', 'consent_suppression_guard',
    jsonb_build_object(
      'reason', left(COALESCE(p_reason, 'unspecified'), 200),
      'suppressed_opportunities', v_suppressed_opportunities,
      'cancelled_sequences', v_cancelled_sequences,
      'cancelled_interventions', v_cancelled_interventions,
      'rejected_pending_deliveries', v_rejected_deliveries
    )
  );

  RETURN jsonb_build_object(
    'suppressed_opportunities', v_suppressed_opportunities,
    'cancelled_sequences', v_cancelled_sequences,
    'cancelled_interventions', v_cancelled_interventions,
    'rejected_pending_deliveries', v_rejected_deliveries
  );
END;
$function$


CREATE OR REPLACE FUNCTION henvalt.unsubscribe_customer_by_token(p_token text)
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'henvalt', 'extensions', 'pg_temp'
AS $function$
DECLARE
  v_token_id uuid;
  v_tenant_id uuid;
  v_customer_id uuid;
  v_used_at timestamptz;
  v_cascade jsonb;
BEGIN
  IF p_token IS NULL OR p_token !~ '^[0-9a-f]{48}$' THEN
    RETURN false;
  END IF;

  SELECT id, tenant_id, customer_id, used_at
    INTO v_token_id, v_tenant_id, v_customer_id, v_used_at
    FROM henvalt.unsubscribe_tokens
   WHERE token_hash = encode(extensions.digest(convert_to(p_token, 'UTF8'), 'sha256'), 'hex')
   LIMIT 1
   FOR UPDATE;

  IF v_token_id IS NULL THEN
    RETURN false;
  END IF;

  IF v_used_at IS NOT NULL THEN
    RETURN true;
  END IF;

  UPDATE henvalt.customers
     SET email_consent = false,
         updated_at = now()
   WHERE id = v_customer_id
     AND tenant_id = v_tenant_id;

  IF NOT FOUND THEN
    RETURN false;
  END IF;

  v_cascade := henvalt.suppress_customer_recovery(v_tenant_id, v_customer_id, 'customer_unsubscribe_link');

  UPDATE henvalt.unsubscribe_tokens
     SET used_at = now()
   WHERE id = v_token_id;

  INSERT INTO henvalt.audit_log (
    tenant_id, event_name, entity_type, entity_id, actor_type, actor_reference, payload
  ) VALUES (
    v_tenant_id, 'email_unsubscribed', 'customer', v_customer_id,
    'external', 'recovery_email_link',
    jsonb_build_object(
      'unsubscribe_token_id', v_token_id,
      'channel', 'EMAIL',
      'recovery_suppression', COALESCE(v_cascade, '{}'::jsonb)
    )
  );

  RETURN true;
END;
$function$


CREATE OR REPLACE FUNCTION henvalt.process_mailersend_webhook_event(p_payload jsonb, p_raw_body_base64 text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'henvalt', 'extensions', 'pg_temp'
AS $function$
DECLARE
  v_body bytea;
  v_hash text;
  v_type text;
  v_data jsonb;
  v_mid text;
  v_email text;
  v_tenant uuid;
  v_req uuid;
  v_customer uuid;
  v_event uuid;
  v_status integer;
  v_time timestamptz;
  v_recovery_suppression jsonb := '{}'::jsonb;
BEGIN
  IF p_payload IS NULL OR jsonb_typeof(p_payload) <> 'object' OR NULLIF(btrim(p_raw_body_base64), '') IS NULL THEN
    RAISE EXCEPTION 'Malformed MailerSend webhook payload';
  END IF;

  v_type := p_payload->>'type';
  IF v_type = 'webhook.test' THEN
    RETURN jsonb_build_object('accepted', true, 'ignored', true);
  END IF;
  IF NULLIF(btrim(v_type), '') IS NULL THEN
    RAISE EXCEPTION 'Event type missing';
  END IF;

  v_body := decode(p_raw_body_base64, 'base64');
  v_hash := encode(extensions.digest(v_body, 'sha256'), 'hex');
  v_data := COALESCE(p_payload->'data', '{}'::jsonb);
  v_mid := NULLIF(v_data->>'message_id', '');
  v_email := lower(NULLIF(v_data->>'email', ''));

  BEGIN
    v_time := NULLIF(p_payload->>'created_at', '')::timestamptz;
  EXCEPTION WHEN OTHERS THEN
    v_time := now();
  END;

  IF jsonb_typeof(v_data->'tags') = 'array' THEN
    SELECT substring(t.tag from '^tenant:([0-9a-fA-F-]{36})$')::uuid
      INTO v_tenant
      FROM jsonb_array_elements_text(v_data->'tags') AS t(tag)
     WHERE t.tag ~* '^tenant:[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
     LIMIT 1;
  END IF;

  INSERT INTO henvalt.provider_events (
    provider, event_hash, event_type, provider_message_id, recipient_email, tenant_id, occurred_at, payload
  ) VALUES (
    'mailersend', v_hash, v_type, v_mid, v_email, v_tenant, v_time, p_payload
  )
  ON CONFLICT (provider, event_hash) DO NOTHING
  RETURNING id INTO v_event;

  IF v_event IS NULL THEN
    SELECT id INTO v_event
      FROM henvalt.provider_events
     WHERE provider = 'mailersend' AND event_hash = v_hash
     LIMIT 1;
    RETURN jsonb_build_object('accepted', true, 'duplicate', true, 'event_id', v_event);
  END IF;

  IF v_tenant IS NOT NULL AND v_mid IS NOT NULL THEN
    SELECT dr.id INTO v_req
      FROM henvalt.delivery_requests dr
     WHERE dr.tenant_id = v_tenant
       AND lower(COALESCE(dr.provider, '')) = 'mailersend'
       AND dr.provider_message_id = v_mid
     ORDER BY dr.created_at DESC
     LIMIT 1
     FOR UPDATE;

    IF v_req IS NULL THEN
      RAISE EXCEPTION 'Provider event is not yet linked to a delivery request';
    END IF;

    UPDATE henvalt.provider_events
       SET delivery_request_id = v_req
     WHERE id = v_event;
  END IF;

  IF v_req IS NOT NULL AND v_type = 'activity.delivered' THEN
    PERFORM henvalt.record_delivery_result(v_req, 'mailersend', v_mid, 200, 'DELIVERED'::henvalt.delivery_state, NULL, false, p_payload);
  ELSIF v_req IS NOT NULL AND v_type IN ('activity.hard_bounced', 'activity.soft_bounced') THEN
    v_status := CASE WHEN v_type = 'activity.hard_bounced' THEN 550 ELSE 450 END;
    PERFORM henvalt.record_delivery_result(v_req, 'mailersend', v_mid, v_status, 'FAILED'::henvalt.delivery_state, upper(replace(v_type, '.', '_')), false, p_payload);
  END IF;

  IF v_tenant IS NOT NULL AND v_email IS NOT NULL
     AND v_type IN ('activity.hard_bounced', 'activity.unsubscribed', 'activity.spam_complaint', 'activity.suppressed') THEN
    SELECT c.id INTO v_customer
      FROM henvalt.customers c
     WHERE c.tenant_id = v_tenant
       AND lower(c.email) = v_email
     ORDER BY c.created_at DESC
     LIMIT 1;

    INSERT INTO henvalt.email_suppressions (
      tenant_id, customer_id, email_normalized, reason, source, provider_event_hash, active
    ) VALUES (
      v_tenant, v_customer, v_email, v_type, 'mailersend', v_hash, true
    )
    ON CONFLICT (tenant_id, email_normalized) WHERE active IS TRUE
    DO UPDATE SET
      customer_id = EXCLUDED.customer_id,
      reason = EXCLUDED.reason,
      source = EXCLUDED.source,
      provider_event_hash = EXCLUDED.provider_event_hash,
      active = true,
      cleared_at = NULL;

    IF v_type IN ('activity.unsubscribed', 'activity.spam_complaint') AND v_customer IS NOT NULL THEN
      UPDATE henvalt.customers
         SET email_consent = false,
             updated_at = now()
       WHERE id = v_customer
         AND tenant_id = v_tenant;
    END IF;

    IF v_customer IS NOT NULL THEN
      v_recovery_suppression := henvalt.suppress_customer_recovery(v_tenant, v_customer, v_type);
    END IF;
  END IF;

  UPDATE henvalt.provider_events
     SET processed_at = now(),
         processing_result = jsonb_build_object(
           'accepted', true,
           'duplicate', false,
           'event_type', v_type,
           'matched_delivery_request', v_req IS NOT NULL,
           'recovery_suppression', v_recovery_suppression
         )
   WHERE id = v_event;

  RETURN jsonb_build_object(
    'accepted', true,
    'duplicate', false,
    'event_id', v_event,
    'matched_delivery_request', v_req IS NOT NULL,
    'recovery_suppression', v_recovery_suppression
  );
END;
$function$


CREATE OR REPLACE FUNCTION henvalt.get_mailersend_token_for_delivery(p_tenant_id uuid, p_delivery_request_id uuid)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'henvalt', 'vault', 'pg_temp'
AS $function$
DECLARE
  v_secret_ref text;
  v_token text;
  v_claimed_id uuid;
  v_verified_domain text;
  v_sender_domain text;
BEGIN
  IF p_tenant_id IS NULL OR p_delivery_request_id IS NULL THEN
    RAISE EXCEPTION 'DELIVERY_IDENTITY_REQUIRED' USING ERRCODE = '22023';
  END IF;

  UPDATE henvalt.delivery_requests dr
     SET provider_claimed_at = clock_timestamp(),
         updated_at = now()
   WHERE dr.id = p_delivery_request_id
     AND dr.tenant_id = p_tenant_id
     AND dr.status = 'UNKNOWN'
     AND dr.channel = 'EMAIL'
     AND lower(COALESCE(dr.provider, '')) = 'mailersend'
     AND dr.provider_claimed_at IS NULL
     AND EXISTS (
       SELECT 1
         FROM henvalt.opportunities o
         JOIN henvalt.customers c
           ON c.id = o.customer_id
          AND c.tenant_id = o.tenant_id
         JOIN henvalt.recovery_interventions ri
           ON ri.id = dr.intervention_id
          AND ri.tenant_id = dr.tenant_id
          AND ri.opportunity_id = o.id
         JOIN henvalt.recovery_sequences rs
           ON rs.id = dr.recovery_id
          AND rs.tenant_id = dr.tenant_id
          AND rs.opportunity_id = o.id
         JOIN henvalt.tenants t
           ON t.id = dr.tenant_id
        WHERE o.id = dr.opportunity_id
          AND o.tenant_id = dr.tenant_id
          AND o.status = 'ELIGIBLE'
          AND c.email_consent IS TRUE
          AND lower(COALESCE(c.email, '')) = lower(dr.recipient_reference)
          AND ri.status = 'SENDING'
          AND rs.status IN ('SCHEDULED', 'ACTIVE')
          AND t.status = 'ACTIVE'
          AND EXISTS (
            SELECT 1
              FROM henvalt.checkouts ck
              JOIN henvalt.shopify_connections sc
                ON sc.tenant_id = ck.tenant_id
               AND lower(sc.shop_domain) = lower(COALESCE(ck.metadata->>'shop_domain', ''))
               AND sc.active IS TRUE
             WHERE ck.id = o.checkout_id
               AND ck.tenant_id = o.tenant_id
          )
          AND NOT EXISTS (
            SELECT 1
              FROM henvalt.orders ord
             WHERE ord.tenant_id = o.tenant_id
               AND ord.checkout_id = o.checkout_id
               AND lower(COALESCE(ord.financial_status, '')) = 'paid'
               AND ord.cancelled_at IS NULL
          )
          AND NOT EXISTS (
            SELECT 1
              FROM henvalt.email_suppressions es
             WHERE es.tenant_id = o.tenant_id
               AND es.active IS TRUE
               AND (es.customer_id = c.id OR lower(es.email_normalized) = lower(dr.recipient_reference))
          )
     )
  RETURNING dr.id INTO v_claimed_id;

  IF v_claimed_id IS NULL THEN
    RAISE EXCEPTION 'DELIVERY_PROVIDER_ATTEMPT_ALREADY_CLAIMED_OR_UNAUTHORIZED'
      USING ERRCODE = '42501';
  END IF;

  SELECT pc.credentials_secret_ref,
         lower(NULLIF(btrim(pc.configuration->>'verified_domain'), '')),
         lower(split_part(si.sender_reference, '@', 2))
    INTO v_secret_ref, v_verified_domain, v_sender_domain
    FROM henvalt.delivery_requests dr
    JOIN henvalt.sending_identities si
      ON si.tenant_id = dr.tenant_id
     AND si.channel = dr.channel
     AND si.delivery_mode = dr.delivery_mode
     AND si.active IS TRUE
    JOIN henvalt.provider_configs pc
      ON pc.id = si.provider_config_id
     AND pc.tenant_id = dr.tenant_id
     AND pc.channel = dr.channel
     AND pc.active IS TRUE
     AND lower(pc.provider) = lower(si.provider)
   WHERE dr.id = v_claimed_id
     AND dr.tenant_id = p_tenant_id
     AND lower(si.provider) = 'mailersend'
     AND pc.configuration->>'credential_validated' = 'true'
     AND NULLIF(btrim(pc.configuration->>'verified_domain'), '') IS NOT NULL
     AND pc.credentials_secret_ref ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
   ORDER BY si.updated_at DESC NULLS LAST, si.created_at DESC
   LIMIT 1;

  IF v_secret_ref IS NULL OR v_verified_domain IS NULL OR v_sender_domain IS NULL
     OR NOT (v_sender_domain = v_verified_domain OR v_sender_domain LIKE '%.' || v_verified_domain) THEN
    RAISE EXCEPTION 'MAILERSEND_PROVIDER_CREDENTIAL_OR_SENDER_DOMAIN_UNVERIFIED'
      USING ERRCODE = '42501';
  END IF;

  SELECT ds.decrypted_secret
    INTO v_token
    FROM vault.decrypted_secrets ds
   WHERE ds.id = v_secret_ref::uuid;

  IF v_token IS NULL OR length(v_token) < 20 THEN
    RAISE EXCEPTION 'MAILERSEND_PROVIDER_CREDENTIAL_UNAVAILABLE' USING ERRCODE = '42501';
  END IF;

  RETURN v_token;
END;
$function$


REVOKE ALL ON FUNCTION henvalt.suppress_customer_recovery(uuid, uuid, text) FROM PUBLIC;

REVOKE ALL ON FUNCTION henvalt.suppress_customer_recovery(uuid, uuid, text) FROM anon, authenticated;

GRANT EXECUTE ON FUNCTION henvalt.suppress_customer_recovery(uuid, uuid, text) TO service_role;
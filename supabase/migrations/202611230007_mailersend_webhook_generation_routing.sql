-- Route MailerSend sent/delivered webhooks through exact delivery identity
-- and late-acceptance settlement before ordinary result recording.
-- Candidate only; depends on 202611230006_late_provider_acceptance_incidents.sql.
BEGIN;

DO $patch$
DECLARE
  v_oid regprocedure;
  v_definition text;
  v_patched text;
BEGIN
  v_oid := to_regprocedure('henvalt.process_mailersend_webhook_event(jsonb,text)');
  IF v_oid IS NULL THEN RAISE EXCEPTION 'MAILERSEND_WEBHOOK_PROCESSOR_MISSING'; END IF;
  IF to_regprocedure('henvalt.settle_late_provider_acceptance(uuid)') IS NULL THEN
    RAISE EXCEPTION 'LATE_PROVIDER_ACCEPTANCE_RPC_MISSING';
  END IF;
  v_definition := pg_get_functiondef(v_oid);

  IF position('v_delivery_request_tag uuid' IN v_definition)>0 THEN
    RAISE EXCEPTION 'MAILERSEND_WEBHOOK_DELIVERY_TAG_PATCH_ALREADY_APPLIED';
  END IF;

  -- Add exact delivery-tag and late-settlement state without replacing the
  -- existing webhook processor's suppression, bounce and audit behavior.
  v_patched := replace(
    v_definition,
    '  v_tenant uuid;',
    '  v_tenant uuid;' || E'\n  v_delivery_request_tag uuid;' ||
    E'\n  v_delivery_tag_count integer := 0;' ||
    E'\n  v_delivery_tag_prefix_count integer := 0;' ||
    E'\n  v_tenant_tag_count integer := 0;' ||
    E'\n  v_tenant_tag_prefix_count integer := 0;' ||
    E'\n  v_late_acceptance boolean := false;' ||
    E'\n  v_request_state henvalt.delivery_state;'
  );
  IF v_patched=v_definition THEN
    RAISE EXCEPTION 'MAILERSEND_WEBHOOK_DECLARATION_PATCH_ANCHOR_MISMATCH';
  END IF;

  -- Parse the optional delivery tag exactly once. A malformed or duplicated
  -- delivery tag is not allowed to fall back to message-id-only matching.
  v_definition := v_patched;
  v_patched := replace(
    v_definition,
    E'  END IF;\n\n  INSERT INTO henvalt.provider_events (',
    E'  END IF;\n\n' ||
    E'  IF jsonb_typeof(v_data->''tags'') = ''array'' THEN\n' ||
    E'    SELECT\n' ||
    E'      count(*) FILTER (WHERE tag ~* ''^delivery:[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$''),\n' ||
    E'      count(*) FILTER (WHERE lower(tag) LIKE ''delivery:%''),\n' ||
    E'      count(*) FILTER (WHERE tag ~* ''^tenant:[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$''),\n' ||
    E'      count(*) FILTER (WHERE lower(tag) LIKE ''tenant:%'')\n' ||
    E'      INTO v_delivery_tag_count,v_delivery_tag_prefix_count,v_tenant_tag_count,v_tenant_tag_prefix_count\n' ||
    E'      FROM jsonb_array_elements_text(v_data->''tags'') AS x(tag);\n' ||
    E'    IF v_delivery_tag_prefix_count > 1 OR v_tenant_tag_prefix_count > 1\n' ||
    E'       OR (v_delivery_tag_prefix_count = 1 AND (v_delivery_tag_count <> 1 OR v_tenant_tag_count <> 1 OR v_tenant_tag_prefix_count <> 1)) THEN\n' ||
    E'      RAISE EXCEPTION ''MAILERSEND_WEBHOOK_TAG_IDENTITY_MALFORMED'';\n' ||
    E'    END IF;\n' ||
    E'    IF v_delivery_tag_count = 1 THEN\n' ||
    E'      SELECT substring(tag from ''^delivery:([0-9a-fA-F-]{36})$'')::uuid INTO v_delivery_request_tag\n' ||
    E'        FROM jsonb_array_elements_text(v_data->''tags'') AS x(tag)\n' ||
    E'       WHERE tag ~* ''^delivery:[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'';\n' ||
    E'    END IF;\n' ||
    E'  END IF;\n\n  INSERT INTO henvalt.provider_events ('
  );
  IF v_patched=v_definition THEN
    RAISE EXCEPTION 'MAILERSEND_WEBHOOK_TAG_PARSE_PATCH_ANCHOR_MISMATCH';
  END IF;

  v_definition := v_patched;
  v_patched := regexp_replace(
    v_definition,
    'SELECT dr\.id INTO v_req\s+FROM henvalt\.delivery_requests dr\s+WHERE dr\.tenant_id = v_tenant\s+AND lower\(COALESCE\(dr\.provider, ''''\)\) = ''mailersend''\s+AND dr\.provider_message_id = v_mid\s+ORDER BY dr\.created_at DESC\s+LIMIT 1;',
    E'IF v_delivery_request_tag IS NOT NULL THEN\n' ||
    E'      SELECT dr.id INTO v_req FROM henvalt.delivery_requests dr\n' ||
    E'       WHERE dr.id=v_delivery_request_tag AND dr.tenant_id=v_tenant\n' ||
    E'         AND lower(COALESCE(dr.provider, ''''))=''mailersend''\n' ||
    E'         AND (dr.provider_message_id IS NULL OR dr.provider_message_id=v_mid)\n' ||
    E'       LIMIT 1;\n' ||
    E'    ELSE\n' ||
    E'      SELECT dr.id INTO v_req FROM henvalt.delivery_requests dr\n' ||
    E'       WHERE dr.tenant_id=v_tenant AND lower(COALESCE(dr.provider, ''''))=''mailersend''\n' ||
    E'         AND dr.provider_message_id=v_mid\n' ||
    E'       ORDER BY dr.created_at DESC LIMIT 1;\n' ||
    E'    END IF;',
    'n'
  );
  IF v_patched=v_definition OR position('WHERE dr.id=v_delivery_request_tag' IN v_patched)=0 THEN
    RAISE EXCEPTION 'MAILERSEND_WEBHOOK_EXACT_TAG_MATCH_PATCH_FAILED';
  END IF;

  v_definition := v_patched;
  v_patched := replace(
    v_definition,
    E'    UPDATE henvalt.provider_events\n       SET delivery_request_id = v_req\n     WHERE id = v_event;\n  END IF;',
    E'    UPDATE henvalt.provider_events\n       SET delivery_request_id = v_req\n     WHERE id = v_event;\n' ||
    E'    IF v_type IN (''activity.sent'',''activity.delivered'') THEN\n' ||
    E'      IF v_delivery_request_tag IS NULL THEN RAISE EXCEPTION ''MAILERSEND_ACCEPTANCE_REQUIRES_EXACT_DELIVERY_TAG''; END IF;\n' ||
    E'      v_late_acceptance := henvalt.settle_late_provider_acceptance(v_event);\n' ||
    E'    END IF;\n  END IF;'
  );
  IF v_patched=v_definition OR position('settle_late_provider_acceptance(v_event)' IN v_patched)=0 THEN
    RAISE EXCEPTION 'MAILERSEND_WEBHOOK_LATE_SETTLEMENT_PATCH_FAILED';
  END IF;

  v_definition := v_patched;
  v_patched := replace(
    v_definition,
    E'  IF v_req IS NOT NULL AND v_type = ''activity.delivered'' THEN\n    PERFORM henvalt.record_delivery_result',
    E'  IF v_req IS NOT NULL AND v_type = ''activity.sent'' AND NOT v_late_acceptance THEN\n' ||
    E'    SELECT status INTO v_request_state FROM henvalt.delivery_requests WHERE id=v_req;\n' ||
    E'    IF v_request_state IN (''PENDING'',''UNKNOWN'') THEN\n' ||
    E'      PERFORM henvalt.record_delivery_result(v_req, ''mailersend'', v_mid, 200, ''ACCEPTED''::henvalt.delivery_state, NULL, false, p_payload);\n' ||
    E'    END IF;\n' ||
    E'  ELSIF v_req IS NOT NULL AND v_type = ''activity.delivered'' AND NOT v_late_acceptance THEN\n    PERFORM henvalt.record_delivery_result'
  );
  IF v_patched=v_definition OR position('v_request_state IN (''PENDING'',''UNKNOWN'')' IN v_patched)=0 THEN
    RAISE EXCEPTION 'MAILERSEND_WEBHOOK_SENT_EVENT_PATCH_FAILED';
  END IF;

  EXECUTE v_patched;
END;
$patch$;

COMMENT ON FUNCTION henvalt.process_mailersend_webhook_event(jsonb,text) IS
  'MailerSend webhook processor with exact delivery-tag matching for sent/delivered events, parent-first late-acceptance settlement, and preserved suppression/bounce handling.';

COMMIT;

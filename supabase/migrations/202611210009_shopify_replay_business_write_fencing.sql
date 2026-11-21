-- Transactional write-boundary fencing for Shopify replay jobs.
-- Each wrapper locks the exact background_jobs row FOR UPDATE and validates the
-- current lease inside the same transaction as the wrapped business mutation.
-- The row lock prevents another claimant from reclaiming the job until commit.

CREATE OR REPLACE FUNCTION henvalt.assert_shopify_replay_lease_for_write(
  p_job_id uuid,
  p_worker_id text,
  p_lease_id uuid
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_job henvalt.background_jobs%ROWTYPE;
BEGIN
  IF p_job_id IS NULL OR NULLIF(btrim(p_worker_id), '') IS NULL OR p_lease_id IS NULL THEN
    RAISE EXCEPTION 'SHOPIFY_REPLAY_WRITE_LEASE_ARGUMENTS_INVALID'
      USING ERRCODE = '22023';
  END IF;

  SELECT j.* INTO v_job
    FROM henvalt.background_jobs AS j
   WHERE j.id = p_job_id
     AND j.job_type = 'process_shopify_webhook'
     AND j.status = 'CLAIMED'::henvalt.job_status
     AND j.locked_by = p_worker_id
     AND j.lease_id = p_lease_id
     AND j.lease_expires_at > clock_timestamp()
   FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'SHOPIFY_REPLAY_WRITE_LEASE_NOT_CURRENT'
      USING ERRCODE = '42501';
  END IF;
END;
$function$;

-- Customer and identity projections
CREATE OR REPLACE FUNCTION henvalt.upsert_customer_fenced(
  p_job_id uuid, p_worker_id text, p_lease_id uuid,
  p_tenant_id uuid, p_shopify_customer_id text, p_email text, p_phone text,
  p_first_name text, p_last_name text, p_email_consent boolean,
  p_whatsapp_consent boolean, p_sms_consent boolean, p_metadata jsonb
)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $function$
BEGIN
  PERFORM henvalt.assert_shopify_replay_lease_for_write(p_job_id,p_worker_id,p_lease_id);
  RETURN henvalt.upsert_customer(p_tenant_id,p_shopify_customer_id,p_email,p_phone,
    p_first_name,p_last_name,p_email_consent,p_whatsapp_consent,p_sms_consent,p_metadata);
END;
$function$;

CREATE OR REPLACE FUNCTION henvalt.apply_shopify_email_consent_update_fenced(
  p_job_id uuid, p_worker_id text, p_lease_id uuid,
  p_tenant_id uuid, p_shopify_customer_id text, p_email text,
  p_email_consent boolean, p_metadata jsonb
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $function$
BEGIN
  PERFORM henvalt.assert_shopify_replay_lease_for_write(p_job_id,p_worker_id,p_lease_id);
  RETURN henvalt.apply_shopify_email_consent_update(
    p_tenant_id,p_shopify_customer_id,p_email,p_email_consent,p_metadata);
END;
$function$;

CREATE OR REPLACE FUNCTION henvalt.bind_session_alias_fenced(
  p_job_id uuid, p_worker_id text, p_lease_id uuid,
  p_tenant_id uuid, p_alias_reference text, p_session_reference text
)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $function$
BEGIN
  PERFORM henvalt.assert_shopify_replay_lease_for_write(p_job_id,p_worker_id,p_lease_id);
  RETURN henvalt.bind_session_alias(p_tenant_id,p_alias_reference,p_session_reference);
END;
$function$;

-- Canonical event, checkout and opportunity writes
CREATE OR REPLACE FUNCTION henvalt.upsert_canonical_event_fenced(
  p_job_id uuid, p_worker_id text, p_lease_id uuid,
  p_tenant_id uuid, p_webhook_event_id uuid, p_event_type text,
  p_event_class henvalt.event_class, p_source text, p_source_event_id text,
  p_customer_reference text, p_email text, p_anonymous_reference text,
  p_session_reference text, p_occurred_at timestamptz, p_value_at_risk numeric,
  p_currency character, p_payload jsonb, p_metadata jsonb,
  p_idempotency_key text, p_correlation_id uuid
)
RETURNS TABLE(event_id uuid,is_duplicate boolean)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $function$
BEGIN
  PERFORM henvalt.assert_shopify_replay_lease_for_write(p_job_id,p_worker_id,p_lease_id);
  RETURN QUERY SELECT * FROM henvalt.upsert_canonical_event(
    p_tenant_id,p_webhook_event_id,p_event_type,p_event_class,p_source,p_source_event_id,
    p_customer_reference,p_email,p_anonymous_reference,p_session_reference,p_occurred_at,
    p_value_at_risk,p_currency,p_payload,p_metadata,p_idempotency_key,p_correlation_id);
END;
$function$;

CREATE OR REPLACE FUNCTION henvalt.upsert_checkout_fenced(
  p_job_id uuid, p_worker_id text, p_lease_id uuid,
  p_tenant_id uuid, p_shopify_checkout_id text, p_customer_id uuid,
  p_checkout_token text, p_session_reference text, p_email text,
  p_total_value numeric, p_currency character, p_status text, p_metadata jsonb
)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $function$
BEGIN
  PERFORM henvalt.assert_shopify_replay_lease_for_write(p_job_id,p_worker_id,p_lease_id);
  RETURN henvalt.upsert_checkout(p_tenant_id,p_shopify_checkout_id,p_customer_id,
    p_checkout_token,p_session_reference,p_email,p_total_value,p_currency,p_status,p_metadata);
END;
$function$;

CREATE OR REPLACE FUNCTION henvalt.create_opportunity_idempotent_fenced(
  p_job_id uuid, p_worker_id text, p_lease_id uuid,
  p_tenant_id uuid, p_source_event_id uuid, p_customer_id uuid, p_checkout_id uuid,
  p_opportunity_type henvalt.opportunity_type, p_value_at_risk numeric,
  p_currency character, p_confidence_score numeric, p_idempotency_key text,
  p_expires_at timestamptz, p_correlation_id uuid
)
RETURNS TABLE(opportunity_id uuid,is_duplicate boolean)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $function$
BEGIN
  PERFORM henvalt.assert_shopify_replay_lease_for_write(p_job_id,p_worker_id,p_lease_id);
  RETURN QUERY SELECT * FROM henvalt.create_opportunity_idempotent(
    p_tenant_id,p_source_event_id,p_customer_id,p_checkout_id,p_opportunity_type,
    p_value_at_risk,p_currency,p_confidence_score,p_idempotency_key,p_expires_at,p_correlation_id);
END;
$function$;

-- Recovery, order attribution and revenue-ledger writes
CREATE OR REPLACE FUNCTION henvalt.create_intervention_and_enqueue_fenced(
  p_job_id uuid, p_worker_id text, p_lease_id uuid,
  p_recovery_id uuid, p_channel henvalt.channel_type, p_step_number integer,
  p_scheduled_at timestamptz, p_template_reference text, p_recipient_reference text,
  p_idempotency_key text, p_correlation_id uuid
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $function$
BEGIN
  PERFORM henvalt.assert_shopify_replay_lease_for_write(p_job_id,p_worker_id,p_lease_id);
  RETURN henvalt.create_intervention_and_enqueue(p_recovery_id,p_channel,p_step_number,
    p_scheduled_at,p_template_reference,p_recipient_reference,p_idempotency_key,p_correlation_id);
END;
$function$;

CREATE OR REPLACE FUNCTION henvalt.project_order_from_event_fenced(
  p_job_id uuid, p_worker_id text, p_lease_id uuid, p_event_id uuid
)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $function$
BEGIN
  PERFORM henvalt.assert_shopify_replay_lease_for_write(p_job_id,p_worker_id,p_lease_id);
  RETURN henvalt.project_order_from_event(p_event_id);
END;
$function$;

CREATE OR REPLACE FUNCTION henvalt.evaluate_order_attribution_fenced(
  p_job_id uuid, p_worker_id text, p_lease_id uuid, p_order_id uuid
)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $function$
BEGIN
  PERFORM henvalt.assert_shopify_replay_lease_for_write(p_job_id,p_worker_id,p_lease_id);
  RETURN henvalt.evaluate_order_attribution(p_order_id);
END;
$function$;

CREATE OR REPLACE FUNCTION henvalt.create_revenue_adjustment_fenced(
  p_job_id uuid, p_worker_id text, p_lease_id uuid,
  p_order_id uuid, p_amount numeric, p_currency character,
  p_reason text, p_source_event_id uuid
)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $function$
BEGIN
  PERFORM henvalt.assert_shopify_replay_lease_for_write(p_job_id,p_worker_id,p_lease_id);
  RETURN henvalt.create_revenue_adjustment(p_order_id,p_amount,p_currency,p_reason,p_source_event_id);
END;
$function$;

CREATE OR REPLACE FUNCTION henvalt.process_shopify_revenue_adjustment_fenced(
  p_job_id uuid, p_worker_id text, p_lease_id uuid, p_event_id uuid
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $function$
BEGIN
  PERFORM henvalt.assert_shopify_replay_lease_for_write(p_job_id,p_worker_id,p_lease_id);
  RETURN henvalt.process_shopify_revenue_adjustment(p_event_id);
END;
$function$;

CREATE OR REPLACE FUNCTION henvalt.deactivate_shopify_connection_on_uninstall_fenced(
  p_job_id uuid, p_worker_id text, p_lease_id uuid,
  p_tenant_id uuid, p_shop_domain text, p_webhook_event_id uuid, p_correlation_id uuid
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $function$
BEGIN
  PERFORM henvalt.assert_shopify_replay_lease_for_write(p_job_id,p_worker_id,p_lease_id);
  RETURN henvalt.deactivate_shopify_connection_on_uninstall(
    p_tenant_id,p_shop_domain,p_webhook_event_id,p_correlation_id);
END;
$function$;

CREATE OR REPLACE FUNCTION henvalt.stop_recovery_after_order_fenced(
  p_job_id uuid, p_worker_id text, p_lease_id uuid, p_attribution_id uuid
)
RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $function$
BEGIN
  PERFORM henvalt.assert_shopify_replay_lease_for_write(p_job_id,p_worker_id,p_lease_id);
  RETURN henvalt.stop_recovery_after_order(p_attribution_id);
END;
$function$;

-- Service-role-only entry points. Do not expose the lease guard to client roles.
REVOKE ALL ON FUNCTION henvalt.assert_shopify_replay_lease_for_write(uuid,text,uuid) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION henvalt.assert_shopify_replay_lease_for_write(uuid,text,uuid) FROM anon,authenticated;
GRANT EXECUTE ON FUNCTION henvalt.assert_shopify_replay_lease_for_write(uuid,text,uuid) TO service_role;

REVOKE ALL ON FUNCTION henvalt.upsert_customer_fenced(uuid,text,uuid,uuid,text,text,text,text,text,boolean,boolean,boolean,jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION henvalt.apply_shopify_email_consent_update_fenced(uuid,text,uuid,uuid,text,text,boolean,jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION henvalt.bind_session_alias_fenced(uuid,text,uuid,uuid,text,text) FROM PUBLIC;
REVOKE ALL ON FUNCTION henvalt.upsert_canonical_event_fenced(uuid,text,uuid,uuid,uuid,text,henvalt.event_class,text,text,text,text,text,text,timestamptz,numeric,character,jsonb,jsonb,text,uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION henvalt.upsert_checkout_fenced(uuid,text,uuid,uuid,text,uuid,text,text,text,numeric,character,text,jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION henvalt.create_opportunity_idempotent_fenced(uuid,text,uuid,uuid,uuid,uuid,uuid,henvalt.opportunity_type,numeric,character,numeric,text,timestamptz,uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION henvalt.create_intervention_and_enqueue_fenced(uuid,text,uuid,uuid,henvalt.channel_type,integer,timestamptz,text,text,text,uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION henvalt.project_order_from_event_fenced(uuid,text,uuid,uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION henvalt.evaluate_order_attribution_fenced(uuid,text,uuid,uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION henvalt.create_revenue_adjustment_fenced(uuid,text,uuid,uuid,numeric,character,text,uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION henvalt.process_shopify_revenue_adjustment_fenced(uuid,text,uuid,uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION henvalt.deactivate_shopify_connection_on_uninstall_fenced(uuid,text,uuid,uuid,text,uuid,uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION henvalt.stop_recovery_after_order_fenced(uuid,text,uuid,uuid) FROM PUBLIC;

REVOKE EXECUTE ON FUNCTION henvalt.upsert_customer_fenced(uuid,text,uuid,uuid,text,text,text,text,text,boolean,boolean,boolean,jsonb) FROM anon,authenticated;
REVOKE EXECUTE ON FUNCTION henvalt.apply_shopify_email_consent_update_fenced(uuid,text,uuid,uuid,text,text,boolean,jsonb) FROM anon,authenticated;
REVOKE EXECUTE ON FUNCTION henvalt.bind_session_alias_fenced(uuid,text,uuid,uuid,text,text) FROM anon,authenticated;
REVOKE EXECUTE ON FUNCTION henvalt.upsert_canonical_event_fenced(uuid,text,uuid,uuid,uuid,text,henvalt.event_class,text,text,text,text,text,text,timestamptz,numeric,character,jsonb,jsonb,text,uuid) FROM anon,authenticated;
REVOKE EXECUTE ON FUNCTION henvalt.upsert_checkout_fenced(uuid,text,uuid,uuid,text,uuid,text,text,text,numeric,character,text,jsonb) FROM anon,authenticated;
REVOKE EXECUTE ON FUNCTION henvalt.create_opportunity_idempotent_fenced(uuid,text,uuid,uuid,uuid,uuid,uuid,henvalt.opportunity_type,numeric,character,numeric,text,timestamptz,uuid) FROM anon,authenticated;
REVOKE EXECUTE ON FUNCTION henvalt.create_intervention_and_enqueue_fenced(uuid,text,uuid,uuid,henvalt.channel_type,integer,timestamptz,text,text,text,uuid) FROM anon,authenticated;
REVOKE EXECUTE ON FUNCTION henvalt.project_order_from_event_fenced(uuid,text,uuid,uuid) FROM anon,authenticated;
REVOKE EXECUTE ON FUNCTION henvalt.evaluate_order_attribution_fenced(uuid,text,uuid,uuid) FROM anon,authenticated;
REVOKE EXECUTE ON FUNCTION henvalt.create_revenue_adjustment_fenced(uuid,text,uuid,uuid,numeric,character,text,uuid) FROM anon,authenticated;
REVOKE EXECUTE ON FUNCTION henvalt.process_shopify_revenue_adjustment_fenced(uuid,text,uuid,uuid) FROM anon,authenticated;
REVOKE EXECUTE ON FUNCTION henvalt.deactivate_shopify_connection_on_uninstall_fenced(uuid,text,uuid,uuid,text,uuid,uuid) FROM anon,authenticated;
REVOKE EXECUTE ON FUNCTION henvalt.stop_recovery_after_order_fenced(uuid,text,uuid,uuid) FROM anon,authenticated;

GRANT EXECUTE ON FUNCTION henvalt.upsert_customer_fenced(uuid,text,uuid,uuid,text,text,text,text,text,boolean,boolean,boolean,jsonb) TO service_role;
GRANT EXECUTE ON FUNCTION henvalt.apply_shopify_email_consent_update_fenced(uuid,text,uuid,uuid,text,text,boolean,jsonb) TO service_role;
GRANT EXECUTE ON FUNCTION henvalt.bind_session_alias_fenced(uuid,text,uuid,uuid,text,text) TO service_role;
GRANT EXECUTE ON FUNCTION henvalt.upsert_canonical_event_fenced(uuid,text,uuid,uuid,uuid,text,henvalt.event_class,text,text,text,text,text,text,timestamptz,numeric,character,jsonb,jsonb,text,uuid) TO service_role;
GRANT EXECUTE ON FUNCTION henvalt.upsert_checkout_fenced(uuid,text,uuid,uuid,text,uuid,text,text,text,numeric,character,text,jsonb) TO service_role;
GRANT EXECUTE ON FUNCTION henvalt.create_opportunity_idempotent_fenced(uuid,text,uuid,uuid,uuid,uuid,uuid,henvalt.opportunity_type,numeric,character,numeric,text,timestamptz,uuid) TO service_role;
GRANT EXECUTE ON FUNCTION henvalt.create_intervention_and_enqueue_fenced(uuid,text,uuid,uuid,henvalt.channel_type,integer,timestamptz,text,text,text,uuid) TO service_role;
GRANT EXECUTE ON FUNCTION henvalt.project_order_from_event_fenced(uuid,text,uuid,uuid) TO service_role;
GRANT EXECUTE ON FUNCTION henvalt.evaluate_order_attribution_fenced(uuid,text,uuid,uuid) TO service_role;
GRANT EXECUTE ON FUNCTION henvalt.create_revenue_adjustment_fenced(uuid,text,uuid,uuid,numeric,character,text,uuid) TO service_role;
GRANT EXECUTE ON FUNCTION henvalt.process_shopify_revenue_adjustment_fenced(uuid,text,uuid,uuid) TO service_role;
GRANT EXECUTE ON FUNCTION henvalt.deactivate_shopify_connection_on_uninstall_fenced(uuid,text,uuid,uuid,text,uuid,uuid) TO service_role;
GRANT EXECUTE ON FUNCTION henvalt.stop_recovery_after_order_fenced(uuid,text,uuid,uuid) TO service_role;

COMMENT ON FUNCTION henvalt.assert_shopify_replay_lease_for_write(uuid,text,uuid) IS
  'Locks the current Shopify replay job row FOR UPDATE and validates the unexpired lease. The row lock is held through the caller transaction, preventing concurrent lease reclaim until its business write commits.';

-- Object-level tenant binding for replay wrappers that accept UUIDs rather
-- than explicit tenant IDs. A valid lease must not authorize a foreign object.
CREATE OR REPLACE FUNCTION henvalt.assert_shopify_replay_object_tenant(
  p_job_id uuid,p_worker_id text,p_lease_id uuid,p_tenant_id uuid,
  p_object_table text,p_object_id uuid
) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $function$
BEGIN
  PERFORM henvalt.assert_shopify_replay_tenant_for_write(p_job_id,p_worker_id,p_lease_id,p_tenant_id);
  IF p_object_id IS NULL THEN RETURN; END IF;
  CASE p_object_table
    WHEN 'customers' THEN
      IF NOT EXISTS (SELECT 1 FROM henvalt.customers x WHERE x.id=p_object_id AND x.tenant_id=p_tenant_id) THEN RAISE EXCEPTION 'SHOPIFY_REPLAY_OBJECT_TENANT_MISMATCH' USING ERRCODE='42501'; END IF;
    WHEN 'checkouts' THEN
      IF NOT EXISTS (SELECT 1 FROM henvalt.checkouts x WHERE x.id=p_object_id AND x.tenant_id=p_tenant_id) THEN RAISE EXCEPTION 'SHOPIFY_REPLAY_OBJECT_TENANT_MISMATCH' USING ERRCODE='42501'; END IF;
    WHEN 'canonical_events' THEN
      IF NOT EXISTS (SELECT 1 FROM henvalt.canonical_events x WHERE x.id=p_object_id AND x.tenant_id=p_tenant_id) THEN RAISE EXCEPTION 'SHOPIFY_REPLAY_OBJECT_TENANT_MISMATCH' USING ERRCODE='42501'; END IF;
    WHEN 'opportunities' THEN
      IF NOT EXISTS (SELECT 1 FROM henvalt.opportunities x WHERE x.id=p_object_id AND x.tenant_id=p_tenant_id) THEN RAISE EXCEPTION 'SHOPIFY_REPLAY_OBJECT_TENANT_MISMATCH' USING ERRCODE='42501'; END IF;
    WHEN 'orders' THEN
      IF NOT EXISTS (SELECT 1 FROM henvalt.orders x WHERE x.id=p_object_id AND x.tenant_id=p_tenant_id) THEN RAISE EXCEPTION 'SHOPIFY_REPLAY_OBJECT_TENANT_MISMATCH' USING ERRCODE='42501'; END IF;
    WHEN 'order_attributions' THEN
      IF NOT EXISTS (SELECT 1 FROM henvalt.order_attributions x WHERE x.id=p_object_id AND x.tenant_id=p_tenant_id) THEN RAISE EXCEPTION 'SHOPIFY_REPLAY_OBJECT_TENANT_MISMATCH' USING ERRCODE='42501'; END IF;
    WHEN 'recovery_sequences' THEN
      IF NOT EXISTS (SELECT 1 FROM henvalt.recovery_sequences x WHERE x.id=p_object_id AND x.tenant_id=p_tenant_id) THEN RAISE EXCEPTION 'SHOPIFY_REPLAY_OBJECT_TENANT_MISMATCH' USING ERRCODE='42501'; END IF;
    WHEN 'recovery_interventions' THEN
      IF NOT EXISTS (SELECT 1 FROM henvalt.recovery_interventions x WHERE x.id=p_object_id AND x.tenant_id=p_tenant_id) THEN RAISE EXCEPTION 'SHOPIFY_REPLAY_OBJECT_TENANT_MISMATCH' USING ERRCODE='42501'; END IF;
    ELSE
      RAISE EXCEPTION 'SHOPIFY_REPLAY_OBJECT_TABLE_NOT_ALLOWED' USING ERRCODE='22023';
  END CASE;
END;
$function$;
REVOKE ALL ON FUNCTION henvalt.assert_shopify_replay_object_tenant(uuid,text,uuid,uuid,text,uuid) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION henvalt.assert_shopify_replay_object_tenant(uuid,text,uuid,uuid,text,uuid) FROM anon,authenticated;
GRANT EXECUTE ON FUNCTION henvalt.assert_shopify_replay_object_tenant(uuid,text,uuid,uuid,text,uuid) TO service_role;

CREATE OR REPLACE FUNCTION henvalt.resolve_identity_fenced(p_job_id uuid,p_worker_id text,p_lease_id uuid,p_event_id uuid)
RETURNS TABLE(customer_id uuid,checkout_id uuid,session_id uuid)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $function$
DECLARE v_tenant uuid;
BEGIN
  PERFORM henvalt.assert_shopify_replay_lease_for_write(p_job_id,p_worker_id,p_lease_id);
  SELECT tenant_id INTO v_tenant FROM henvalt.background_jobs WHERE id=p_job_id;
  PERFORM henvalt.assert_shopify_replay_object_tenant(p_job_id,p_worker_id,p_lease_id,v_tenant,'canonical_events',p_event_id);
  RETURN QUERY SELECT * FROM henvalt.resolve_identity(p_event_id);
END;
$function$;

CREATE OR REPLACE FUNCTION henvalt.upsert_checkout_fenced(
 p_job_id uuid,p_worker_id text,p_lease_id uuid,p_tenant_id uuid,p_shopify_checkout_id text,
 p_customer_id uuid,p_checkout_token text,p_session_reference text,p_email text,
 p_total_value numeric,p_currency character,p_status text,p_metadata jsonb
) RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $function$
BEGIN
 PERFORM henvalt.assert_shopify_replay_tenant_for_write(p_job_id,p_worker_id,p_lease_id,p_tenant_id);
 PERFORM henvalt.assert_shopify_replay_object_tenant(p_job_id,p_worker_id,p_lease_id,p_tenant_id,'customers',p_customer_id);
 RETURN henvalt.upsert_checkout(p_tenant_id,p_shopify_checkout_id,p_customer_id,p_checkout_token,p_session_reference,p_email,p_total_value,p_currency,p_status,p_metadata);
END;
$function$;

CREATE OR REPLACE FUNCTION henvalt.create_opportunity_idempotent_fenced(
 p_job_id uuid,p_worker_id text,p_lease_id uuid,p_tenant_id uuid,p_source_event_id uuid,
 p_customer_id uuid,p_checkout_id uuid,p_opportunity_type henvalt.opportunity_type,
 p_value_at_risk numeric,p_currency character,p_confidence_score numeric,p_idempotency_key text,
 p_expires_at timestamptz,p_correlation_id uuid
) RETURNS TABLE(opportunity_id uuid,is_duplicate boolean)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $function$
BEGIN
 PERFORM henvalt.assert_shopify_replay_tenant_for_write(p_job_id,p_worker_id,p_lease_id,p_tenant_id);
 PERFORM henvalt.assert_shopify_replay_object_tenant(p_job_id,p_worker_id,p_lease_id,p_tenant_id,'canonical_events',p_source_event_id);
 PERFORM henvalt.assert_shopify_replay_object_tenant(p_job_id,p_worker_id,p_lease_id,p_tenant_id,'customers',p_customer_id);
 PERFORM henvalt.assert_shopify_replay_object_tenant(p_job_id,p_worker_id,p_lease_id,p_tenant_id,'checkouts',p_checkout_id);
 RETURN QUERY SELECT * FROM henvalt.create_opportunity_idempotent(p_tenant_id,p_source_event_id,p_customer_id,p_checkout_id,p_opportunity_type,p_value_at_risk,p_currency,p_confidence_score,p_idempotency_key,p_expires_at,p_correlation_id);
END;
$function$;

CREATE OR REPLACE FUNCTION henvalt.apply_eligibility_fenced(p_job_id uuid,p_worker_id text,p_lease_id uuid,p_opportunity_id uuid,p_status henvalt.opportunity_status)
RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $function$
DECLARE v_tenant uuid;
BEGIN
 SELECT tenant_id INTO v_tenant FROM henvalt.background_jobs WHERE id=p_job_id;
 PERFORM henvalt.assert_shopify_replay_object_tenant(p_job_id,p_worker_id,p_lease_id,v_tenant,'opportunities',p_opportunity_id);
 RETURN henvalt.apply_eligibility(p_opportunity_id,p_status);
END;
$function$;

CREATE OR REPLACE FUNCTION henvalt.create_recovery_sequence_fenced(p_job_id uuid,p_worker_id text,p_lease_id uuid,p_opportunity_id uuid)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $function$
DECLARE v_tenant uuid;
BEGIN
 SELECT tenant_id INTO v_tenant FROM henvalt.background_jobs WHERE id=p_job_id;
 PERFORM henvalt.assert_shopify_replay_object_tenant(p_job_id,p_worker_id,p_lease_id,v_tenant,'opportunities',p_opportunity_id);
 RETURN henvalt.create_recovery_sequence(p_opportunity_id);
END;
$function$;

CREATE OR REPLACE FUNCTION henvalt.create_intervention_and_enqueue_fenced(
 p_job_id uuid,p_worker_id text,p_lease_id uuid,p_recovery_id uuid,p_channel henvalt.channel_type,
 p_step_number integer,p_scheduled_at timestamptz,p_template_reference text,p_recipient_reference text,
 p_idempotency_key text,p_correlation_id uuid
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $function$
DECLARE v_tenant uuid;
BEGIN
 SELECT tenant_id INTO v_tenant FROM henvalt.background_jobs WHERE id=p_job_id;
 PERFORM henvalt.assert_shopify_replay_object_tenant(p_job_id,p_worker_id,p_lease_id,v_tenant,'recovery_sequences',p_recovery_id);
 RETURN henvalt.create_intervention_and_enqueue(p_recovery_id,p_channel,p_step_number,p_scheduled_at,p_template_reference,p_recipient_reference,p_idempotency_key,p_correlation_id);
END;
$function$;

CREATE OR REPLACE FUNCTION henvalt.project_order_from_event_fenced(p_job_id uuid,p_worker_id text,p_lease_id uuid,p_event_id uuid)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $function$
DECLARE v_tenant uuid;
BEGIN
 SELECT tenant_id INTO v_tenant FROM henvalt.background_jobs WHERE id=p_job_id;
 PERFORM henvalt.assert_shopify_replay_object_tenant(p_job_id,p_worker_id,p_lease_id,v_tenant,'canonical_events',p_event_id);
 RETURN henvalt.project_order_from_event(p_event_id);
END;
$function$;

CREATE OR REPLACE FUNCTION henvalt.evaluate_order_attribution_fenced(p_job_id uuid,p_worker_id text,p_lease_id uuid,p_order_id uuid)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $function$
DECLARE v_tenant uuid;
BEGIN
 SELECT tenant_id INTO v_tenant FROM henvalt.background_jobs WHERE id=p_job_id;
 PERFORM henvalt.assert_shopify_replay_object_tenant(p_job_id,p_worker_id,p_lease_id,v_tenant,'orders',p_order_id);
 RETURN henvalt.evaluate_order_attribution(p_order_id);
END;
$function$;

CREATE OR REPLACE FUNCTION henvalt.create_revenue_adjustment_fenced(
 p_job_id uuid,p_worker_id text,p_lease_id uuid,p_order_id uuid,p_amount numeric,p_currency character,p_reason text,p_source_event_id uuid
) RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $function$
DECLARE v_tenant uuid;
BEGIN
 SELECT tenant_id INTO v_tenant FROM henvalt.background_jobs WHERE id=p_job_id;
 PERFORM henvalt.assert_shopify_replay_object_tenant(p_job_id,p_worker_id,p_lease_id,v_tenant,'orders',p_order_id);
 PERFORM henvalt.assert_shopify_replay_object_tenant(p_job_id,p_worker_id,p_lease_id,v_tenant,'canonical_events',p_source_event_id);
 RETURN henvalt.create_revenue_adjustment(p_order_id,p_amount,p_currency,p_reason,p_source_event_id);
END;
$function$;

CREATE OR REPLACE FUNCTION henvalt.process_shopify_revenue_adjustment_fenced(p_job_id uuid,p_worker_id text,p_lease_id uuid,p_event_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $function$
DECLARE v_tenant uuid;
BEGIN
 SELECT tenant_id INTO v_tenant FROM henvalt.background_jobs WHERE id=p_job_id;
 PERFORM henvalt.assert_shopify_replay_object_tenant(p_job_id,p_worker_id,p_lease_id,v_tenant,'canonical_events',p_event_id);
 RETURN henvalt.process_shopify_revenue_adjustment(p_event_id);
END;
$function$;

CREATE OR REPLACE FUNCTION henvalt.stop_recovery_after_order_fenced(p_job_id uuid,p_worker_id text,p_lease_id uuid,p_attribution_id uuid)
RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $function$
DECLARE v_tenant uuid;
BEGIN
 SELECT tenant_id INTO v_tenant FROM henvalt.background_jobs WHERE id=p_job_id;
 PERFORM henvalt.assert_shopify_replay_object_tenant(p_job_id,p_worker_id,p_lease_id,v_tenant,'order_attributions',p_attribution_id);
 RETURN henvalt.stop_recovery_after_order(p_attribution_id);
END;
$function$;

CREATE OR REPLACE FUNCTION henvalt.post_recovery_to_ledger_and_measure_billing_fenced(p_job_id uuid,p_worker_id text,p_lease_id uuid,p_attribution_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $function$
DECLARE v_tenant uuid;
BEGIN
 SELECT tenant_id INTO v_tenant FROM henvalt.background_jobs WHERE id=p_job_id;
 PERFORM henvalt.assert_shopify_replay_object_tenant(p_job_id,p_worker_id,p_lease_id,v_tenant,'order_attributions',p_attribution_id);
 RETURN henvalt.post_recovery_to_ledger_and_measure_billing(p_attribution_id);
END;
$function$;

-- Keep all redefined wrappers service-role only, preserving signatures.
REVOKE ALL ON FUNCTION henvalt.resolve_identity_fenced(uuid,text,uuid,uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION henvalt.upsert_checkout_fenced(uuid,text,uuid,uuid,text,uuid,text,text,text,numeric,character,text,jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION henvalt.create_opportunity_idempotent_fenced(uuid,text,uuid,uuid,uuid,uuid,uuid,henvalt.opportunity_type,numeric,character,numeric,text,timestamptz,uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION henvalt.apply_eligibility_fenced(uuid,text,uuid,uuid,henvalt.opportunity_status) FROM PUBLIC;
REVOKE ALL ON FUNCTION henvalt.create_recovery_sequence_fenced(uuid,text,uuid,uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION henvalt.create_intervention_and_enqueue_fenced(uuid,text,uuid,uuid,henvalt.channel_type,integer,timestamptz,text,text,text,uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION henvalt.project_order_from_event_fenced(uuid,text,uuid,uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION henvalt.evaluate_order_attribution_fenced(uuid,text,uuid,uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION henvalt.create_revenue_adjustment_fenced(uuid,text,uuid,uuid,numeric,character,text,uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION henvalt.process_shopify_revenue_adjustment_fenced(uuid,text,uuid,uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION henvalt.stop_recovery_after_order_fenced(uuid,text,uuid,uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION henvalt.post_recovery_to_ledger_and_measure_billing_fenced(uuid,text,uuid,uuid) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION henvalt.resolve_identity_fenced(uuid,text,uuid,uuid) FROM anon,authenticated;
REVOKE EXECUTE ON FUNCTION henvalt.upsert_checkout_fenced(uuid,text,uuid,uuid,text,uuid,text,text,text,numeric,character,text,jsonb) FROM anon,authenticated;
REVOKE EXECUTE ON FUNCTION henvalt.create_opportunity_idempotent_fenced(uuid,text,uuid,uuid,uuid,uuid,uuid,henvalt.opportunity_type,numeric,character,numeric,text,timestamptz,uuid) FROM anon,authenticated;
REVOKE EXECUTE ON FUNCTION henvalt.apply_eligibility_fenced(uuid,text,uuid,uuid,henvalt.opportunity_status) FROM anon,authenticated;
REVOKE EXECUTE ON FUNCTION henvalt.create_recovery_sequence_fenced(uuid,text,uuid,uuid) FROM anon,authenticated;
REVOKE EXECUTE ON FUNCTION henvalt.create_intervention_and_enqueue_fenced(uuid,text,uuid,uuid,henvalt.channel_type,integer,timestamptz,text,text,text,uuid) FROM anon,authenticated;
REVOKE EXECUTE ON FUNCTION henvalt.project_order_from_event_fenced(uuid,text,uuid,uuid) FROM anon,authenticated;
REVOKE EXECUTE ON FUNCTION henvalt.evaluate_order_attribution_fenced(uuid,text,uuid,uuid) FROM anon,authenticated;
REVOKE EXECUTE ON FUNCTION henvalt.create_revenue_adjustment_fenced(uuid,text,uuid,uuid,numeric,character,text,uuid) FROM anon,authenticated;
REVOKE EXECUTE ON FUNCTION henvalt.process_shopify_revenue_adjustment_fenced(uuid,text,uuid,uuid) FROM anon,authenticated;
REVOKE EXECUTE ON FUNCTION henvalt.stop_recovery_after_order_fenced(uuid,text,uuid,uuid) FROM anon,authenticated;
REVOKE EXECUTE ON FUNCTION henvalt.post_recovery_to_ledger_and_measure_billing_fenced(uuid,text,uuid,uuid) FROM anon,authenticated;
GRANT EXECUTE ON FUNCTION henvalt.resolve_identity_fenced(uuid,text,uuid,uuid) TO service_role;
GRANT EXECUTE ON FUNCTION henvalt.upsert_checkout_fenced(uuid,text,uuid,uuid,text,uuid,text,text,text,numeric,character,text,jsonb) TO service_role;
GRANT EXECUTE ON FUNCTION henvalt.create_opportunity_idempotent_fenced(uuid,text,uuid,uuid,uuid,uuid,uuid,henvalt.opportunity_type,numeric,character,numeric,text,timestamptz,uuid) TO service_role;
GRANT EXECUTE ON FUNCTION henvalt.apply_eligibility_fenced(uuid,text,uuid,uuid,henvalt.opportunity_status) TO service_role;
GRANT EXECUTE ON FUNCTION henvalt.create_recovery_sequence_fenced(uuid,text,uuid,uuid) TO service_role;
GRANT EXECUTE ON FUNCTION henvalt.create_intervention_and_enqueue_fenced(uuid,text,uuid,uuid,henvalt.channel_type,integer,timestamptz,text,text,text,uuid) TO service_role;
GRANT EXECUTE ON FUNCTION henvalt.project_order_from_event_fenced(uuid,text,uuid,uuid) TO service_role;
GRANT EXECUTE ON FUNCTION henvalt.evaluate_order_attribution_fenced(uuid,text,uuid,uuid) TO service_role;
GRANT EXECUTE ON FUNCTION henvalt.create_revenue_adjustment_fenced(uuid,text,uuid,uuid,numeric,character,text,uuid) TO service_role;
GRANT EXECUTE ON FUNCTION henvalt.process_shopify_revenue_adjustment_fenced(uuid,text,uuid,uuid) TO service_role;
GRANT EXECUTE ON FUNCTION henvalt.stop_recovery_after_order_fenced(uuid,text,uuid,uuid) TO service_role;
GRANT EXECUTE ON FUNCTION henvalt.post_recovery_to_ledger_and_measure_billing_fenced(uuid,text,uuid,uuid) TO service_role;

CREATE OR REPLACE FUNCTION henvalt.deactivate_shopify_connection_on_uninstall_fenced(
 p_job_id uuid,p_worker_id text,p_lease_id uuid,p_tenant_id uuid,p_shop_domain text,
 p_webhook_event_id uuid,p_correlation_id uuid
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $function$
BEGIN
 PERFORM henvalt.assert_shopify_replay_tenant_for_write(p_job_id,p_worker_id,p_lease_id,p_tenant_id);
 PERFORM henvalt.assert_shopify_replay_webhook_for_write(p_job_id,p_worker_id,p_lease_id,p_webhook_event_id);
 RETURN henvalt.deactivate_shopify_connection_on_uninstall(p_tenant_id,p_shop_domain,p_webhook_event_id,p_correlation_id);
END;
$function$;

CREATE OR REPLACE FUNCTION henvalt.defer_payment_webhook_reconciliation_fenced(
 p_job_id uuid,p_worker_id text,p_lease_id uuid,p_webhook_id uuid,p_error text
) RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $function$
BEGIN
 PERFORM henvalt.assert_shopify_replay_webhook_for_write(p_job_id,p_worker_id,p_lease_id,p_webhook_id);
 RETURN henvalt.defer_payment_webhook_reconciliation(p_webhook_id,p_error);
END;
$function$;
REVOKE ALL ON FUNCTION henvalt.deactivate_shopify_connection_on_uninstall_fenced(uuid,text,uuid,uuid,text,uuid,uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION henvalt.defer_payment_webhook_reconciliation_fenced(uuid,text,uuid,uuid,text) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION henvalt.deactivate_shopify_connection_on_uninstall_fenced(uuid,text,uuid,uuid,text,uuid,uuid) FROM anon,authenticated;
REVOKE EXECUTE ON FUNCTION henvalt.defer_payment_webhook_reconciliation_fenced(uuid,text,uuid,uuid,text) FROM anon,authenticated;
GRANT EXECUTE ON FUNCTION henvalt.deactivate_shopify_connection_on_uninstall_fenced(uuid,text,uuid,uuid,text,uuid,uuid) TO service_role;
GRANT EXECUTE ON FUNCTION henvalt.defer_payment_webhook_reconciliation_fenced(uuid,text,uuid,uuid,text) TO service_role;

-- Validate the tenant of the referenced object graph as well as the root row.
-- Foreign keys on UUID alone do not prevent cross-tenant relationships.
CREATE OR REPLACE FUNCTION henvalt.assert_shopify_replay_object_graph_tenant(
 p_tenant_id uuid,p_object_table text,p_object_id uuid
) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $function$
DECLARE v_valid boolean := false;
        v_root_exists boolean := false;
BEGIN
 IF p_tenant_id IS NULL OR p_object_id IS NULL THEN
  RAISE EXCEPTION 'SHOPIFY_REPLAY_OBJECT_GRAPH_ARGUMENTS_INVALID'
   USING ERRCODE='22023';
 END IF;
 CASE p_object_table
  WHEN 'customers' THEN
   SELECT EXISTS (SELECT 1 FROM henvalt.customers x
     WHERE x.id=p_object_id AND x.tenant_id=p_tenant_id)
    INTO v_root_exists;
   v_valid := v_root_exists;
  WHEN 'checkouts' THEN
   SELECT EXISTS (SELECT 1 FROM henvalt.checkouts x
     WHERE x.id=p_object_id AND x.tenant_id=p_tenant_id)
    INTO v_root_exists;
   SELECT NOT EXISTS (SELECT 1 FROM henvalt.checkouts x
     LEFT JOIN henvalt.customers c ON c.id=x.customer_id
     WHERE x.id=p_object_id AND x.tenant_id=p_tenant_id
       AND x.customer_id IS NOT NULL AND (c.id IS NULL OR c.tenant_id IS DISTINCT FROM p_tenant_id))
    INTO v_valid;
  WHEN 'canonical_events' THEN
   SELECT EXISTS (SELECT 1 FROM henvalt.canonical_events x
     WHERE x.id=p_object_id AND x.tenant_id=p_tenant_id)
    INTO v_root_exists;
   SELECT NOT EXISTS (SELECT 1 FROM henvalt.canonical_events x
     LEFT JOIN henvalt.webhook_events w ON w.id=x.webhook_event_id
     WHERE x.id=p_object_id AND x.tenant_id=p_tenant_id
       AND x.webhook_event_id IS NOT NULL AND (w.id IS NULL OR w.tenant_id IS DISTINCT FROM p_tenant_id))
    INTO v_valid;
  WHEN 'opportunities' THEN
   SELECT EXISTS (SELECT 1 FROM henvalt.opportunities x
     WHERE x.id=p_object_id AND x.tenant_id=p_tenant_id)
    INTO v_root_exists;
   SELECT NOT EXISTS (SELECT 1 FROM henvalt.opportunities x
     LEFT JOIN henvalt.customers c ON c.id=x.customer_id
     LEFT JOIN henvalt.checkouts co ON co.id=x.checkout_id
     LEFT JOIN henvalt.canonical_events e ON e.id=x.source_event_id
     WHERE x.id=p_object_id AND x.tenant_id=p_tenant_id
       AND ((x.customer_id IS NOT NULL AND (c.id IS NULL OR c.tenant_id IS DISTINCT FROM p_tenant_id))
         OR (x.checkout_id IS NOT NULL AND (co.id IS NULL OR co.tenant_id IS DISTINCT FROM p_tenant_id))
         OR (x.source_event_id IS NOT NULL AND (e.id IS NULL OR e.tenant_id IS DISTINCT FROM p_tenant_id))))
    INTO v_valid;
  WHEN 'orders' THEN
   SELECT EXISTS (SELECT 1 FROM henvalt.orders x
     WHERE x.id=p_object_id AND x.tenant_id=p_tenant_id)
    INTO v_root_exists;
   SELECT NOT EXISTS (SELECT 1 FROM henvalt.orders x
     LEFT JOIN henvalt.customers c ON c.id=x.customer_id
     LEFT JOIN henvalt.checkouts co ON co.id=x.checkout_id
     WHERE x.id=p_object_id AND x.tenant_id=p_tenant_id
       AND ((x.customer_id IS NOT NULL AND (c.id IS NULL OR c.tenant_id IS DISTINCT FROM p_tenant_id))
         OR (x.checkout_id IS NOT NULL AND (co.id IS NULL OR co.tenant_id IS DISTINCT FROM p_tenant_id))))
    INTO v_valid;
  WHEN 'recovery_sequences' THEN
   SELECT EXISTS (SELECT 1 FROM henvalt.recovery_sequences x
     WHERE x.id=p_object_id AND x.tenant_id=p_tenant_id)
    INTO v_root_exists;
   SELECT NOT EXISTS (SELECT 1 FROM henvalt.recovery_sequences x
     LEFT JOIN henvalt.opportunities o ON o.id=x.opportunity_id
     WHERE x.id=p_object_id AND x.tenant_id=p_tenant_id
       AND (o.id IS NULL OR o.tenant_id IS DISTINCT FROM p_tenant_id))
    INTO v_valid;
  WHEN 'recovery_interventions' THEN
   SELECT EXISTS (SELECT 1 FROM henvalt.recovery_interventions x
     WHERE x.id=p_object_id AND x.tenant_id=p_tenant_id)
    INTO v_root_exists;
   SELECT NOT EXISTS (SELECT 1 FROM henvalt.recovery_interventions x
     LEFT JOIN henvalt.recovery_sequences s ON s.id=x.sequence_id
     LEFT JOIN henvalt.opportunities o ON o.id=x.opportunity_id
     WHERE x.id=p_object_id AND x.tenant_id=p_tenant_id
       AND ((x.sequence_id IS NOT NULL AND (s.id IS NULL OR s.tenant_id IS DISTINCT FROM p_tenant_id))
         OR (x.opportunity_id IS NOT NULL AND (o.id IS NULL OR o.tenant_id IS DISTINCT FROM p_tenant_id))))
    INTO v_valid;
  WHEN 'order_attributions' THEN
   SELECT EXISTS (SELECT 1 FROM henvalt.order_attributions x
     WHERE x.id=p_object_id AND x.tenant_id=p_tenant_id)
    INTO v_root_exists;
   SELECT NOT EXISTS (SELECT 1 FROM henvalt.order_attributions x
     LEFT JOIN henvalt.orders o ON o.id=x.order_id
     LEFT JOIN henvalt.recovery_sequences s ON s.id=x.recovery_id
     LEFT JOIN henvalt.opportunities p ON p.id=x.opportunity_id
     LEFT JOIN henvalt.recovery_interventions i ON i.id=x.matched_intervention_id
     WHERE x.id=p_object_id AND x.tenant_id=p_tenant_id
       AND ((x.order_id IS NOT NULL AND (o.id IS NULL OR o.tenant_id IS DISTINCT FROM p_tenant_id))
         OR (x.recovery_id IS NOT NULL AND (s.id IS NULL OR s.tenant_id IS DISTINCT FROM p_tenant_id))
         OR (x.opportunity_id IS NOT NULL AND (p.id IS NULL OR p.tenant_id IS DISTINCT FROM p_tenant_id))
         OR (x.matched_intervention_id IS NOT NULL AND (i.id IS NULL OR i.tenant_id IS DISTINCT FROM p_tenant_id))))
    INTO v_valid;
  ELSE
   RAISE EXCEPTION 'SHOPIFY_REPLAY_OBJECT_TABLE_NOT_ALLOWED'
    USING ERRCODE='22023';
 END CASE;
 IF NOT COALESCE(v_root_exists,false) THEN
  RAISE EXCEPTION 'SHOPIFY_REPLAY_OBJECT_GRAPH_ROOT_TENANT_MISMATCH'
   USING ERRCODE='42501';
 END IF;
 IF NOT COALESCE(v_valid,false) THEN
  RAISE EXCEPTION 'SHOPIFY_REPLAY_OBJECT_GRAPH_TENANT_MISMATCH'
   USING ERRCODE='42501';
 END IF;
END;
$function$;
REVOKE ALL ON FUNCTION henvalt.assert_shopify_replay_object_graph_tenant(uuid,text,uuid) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION henvalt.assert_shopify_replay_object_graph_tenant(uuid,text,uuid) FROM anon,authenticated;
GRANT EXECUTE ON FUNCTION henvalt.assert_shopify_replay_object_graph_tenant(uuid,text,uuid) TO service_role;

CREATE OR REPLACE FUNCTION henvalt.assert_shopify_replay_object_tenant(
 p_job_id uuid,p_worker_id text,p_lease_id uuid,p_tenant_id uuid,
 p_object_table text,p_object_id uuid
) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $function$
BEGIN
 PERFORM henvalt.assert_shopify_replay_tenant_for_write(p_job_id,p_worker_id,p_lease_id,p_tenant_id);
 IF p_object_id IS NULL THEN RETURN; END IF;
 CASE p_object_table
  WHEN 'customers' THEN
   IF NOT EXISTS (SELECT 1 FROM henvalt.customers x WHERE x.id=p_object_id AND x.tenant_id=p_tenant_id) THEN RAISE EXCEPTION 'SHOPIFY_REPLAY_OBJECT_TENANT_MISMATCH' USING ERRCODE='42501'; END IF;
  WHEN 'checkouts' THEN
   IF NOT EXISTS (SELECT 1 FROM henvalt.checkouts x WHERE x.id=p_object_id AND x.tenant_id=p_tenant_id) THEN RAISE EXCEPTION 'SHOPIFY_REPLAY_OBJECT_TENANT_MISMATCH' USING ERRCODE='42501'; END IF;
  WHEN 'canonical_events' THEN
   IF NOT EXISTS (SELECT 1 FROM henvalt.canonical_events x WHERE x.id=p_object_id AND x.tenant_id=p_tenant_id) THEN RAISE EXCEPTION 'SHOPIFY_REPLAY_OBJECT_TENANT_MISMATCH' USING ERRCODE='42501'; END IF;
  WHEN 'opportunities' THEN
   IF NOT EXISTS (SELECT 1 FROM henvalt.opportunities x WHERE x.id=p_object_id AND x.tenant_id=p_tenant_id) THEN RAISE EXCEPTION 'SHOPIFY_REPLAY_OBJECT_TENANT_MISMATCH' USING ERRCODE='42501'; END IF;
  WHEN 'orders' THEN
   IF NOT EXISTS (SELECT 1 FROM henvalt.orders x WHERE x.id=p_object_id AND x.tenant_id=p_tenant_id) THEN RAISE EXCEPTION 'SHOPIFY_REPLAY_OBJECT_TENANT_MISMATCH' USING ERRCODE='42501'; END IF;
  WHEN 'order_attributions' THEN
   IF NOT EXISTS (SELECT 1 FROM henvalt.order_attributions x WHERE x.id=p_object_id AND x.tenant_id=p_tenant_id) THEN RAISE EXCEPTION 'SHOPIFY_REPLAY_OBJECT_TENANT_MISMATCH' USING ERRCODE='42501'; END IF;
  WHEN 'recovery_sequences' THEN
   IF NOT EXISTS (SELECT 1 FROM henvalt.recovery_sequences x WHERE x.id=p_object_id AND x.tenant_id=p_tenant_id) THEN RAISE EXCEPTION 'SHOPIFY_REPLAY_OBJECT_TENANT_MISMATCH' USING ERRCODE='42501'; END IF;
  WHEN 'recovery_interventions' THEN
   IF NOT EXISTS (SELECT 1 FROM henvalt.recovery_interventions x WHERE x.id=p_object_id AND x.tenant_id=p_tenant_id) THEN RAISE EXCEPTION 'SHOPIFY_REPLAY_OBJECT_TENANT_MISMATCH' USING ERRCODE='42501'; END IF;
  ELSE RAISE EXCEPTION 'SHOPIFY_REPLAY_OBJECT_TABLE_NOT_ALLOWED' USING ERRCODE='22023';
 END CASE;
 PERFORM henvalt.assert_shopify_replay_object_graph_tenant(p_tenant_id,p_object_table,p_object_id);
END;
$function$;

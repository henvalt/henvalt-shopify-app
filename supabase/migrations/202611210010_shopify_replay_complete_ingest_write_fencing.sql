-- Complete the replay lease-fenced write boundary for all mutating
-- Shopify ingest RPCs discovered in the active HENVALT_INGEST graph.
-- These wrappers lock and validate the replay lease in the same transaction
-- as the underlying mutation. Candidate-only until isolated staging.

CREATE OR REPLACE FUNCTION henvalt.apply_eligibility_fenced(
  p_job_id uuid, p_worker_id text, p_lease_id uuid,
  p_opportunity_id uuid, p_status henvalt.opportunity_status
)
RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $function$
BEGIN
  PERFORM henvalt.assert_shopify_replay_lease_for_write(p_job_id,p_worker_id,p_lease_id);
  RETURN henvalt.apply_eligibility(p_opportunity_id,p_status);
END;
$function$;

CREATE OR REPLACE FUNCTION henvalt.create_recovery_sequence_fenced(
  p_job_id uuid, p_worker_id text, p_lease_id uuid, p_opportunity_id uuid
)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $function$
BEGIN
  PERFORM henvalt.assert_shopify_replay_lease_for_write(p_job_id,p_worker_id,p_lease_id);
  RETURN henvalt.create_recovery_sequence(p_opportunity_id);
END;
$function$;

CREATE OR REPLACE FUNCTION henvalt.post_recovery_to_ledger_and_measure_billing_fenced(
  p_job_id uuid, p_worker_id text, p_lease_id uuid, p_attribution_id uuid
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $function$
BEGIN
  PERFORM henvalt.assert_shopify_replay_lease_for_write(p_job_id,p_worker_id,p_lease_id);
  RETURN henvalt.post_recovery_to_ledger_and_measure_billing(p_attribution_id);
END;
$function$;

CREATE OR REPLACE FUNCTION henvalt.defer_payment_webhook_reconciliation_fenced(
  p_job_id uuid, p_worker_id text, p_lease_id uuid, p_webhook_id uuid, p_error text
)
RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $function$
BEGIN
  PERFORM henvalt.assert_shopify_replay_lease_for_write(p_job_id,p_worker_id,p_lease_id);
  RETURN henvalt.defer_payment_webhook_reconciliation(p_webhook_id,p_error);
END;
$function$;

REVOKE ALL ON FUNCTION henvalt.apply_eligibility_fenced(uuid,text,uuid,uuid,henvalt.opportunity_status) FROM PUBLIC;
REVOKE ALL ON FUNCTION henvalt.create_recovery_sequence_fenced(uuid,text,uuid,uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION henvalt.post_recovery_to_ledger_and_measure_billing_fenced(uuid,text,uuid,uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION henvalt.defer_payment_webhook_reconciliation_fenced(uuid,text,uuid,uuid,text) FROM PUBLIC;

REVOKE EXECUTE ON FUNCTION henvalt.apply_eligibility_fenced(uuid,text,uuid,uuid,henvalt.opportunity_status) FROM anon,authenticated;
REVOKE EXECUTE ON FUNCTION henvalt.create_recovery_sequence_fenced(uuid,text,uuid,uuid) FROM anon,authenticated;
REVOKE EXECUTE ON FUNCTION henvalt.post_recovery_to_ledger_and_measure_billing_fenced(uuid,text,uuid,uuid) FROM anon,authenticated;
REVOKE EXECUTE ON FUNCTION henvalt.defer_payment_webhook_reconciliation_fenced(uuid,text,uuid,uuid,text) FROM anon,authenticated;

GRANT EXECUTE ON FUNCTION henvalt.apply_eligibility_fenced(uuid,text,uuid,uuid,henvalt.opportunity_status) TO service_role;
GRANT EXECUTE ON FUNCTION henvalt.create_recovery_sequence_fenced(uuid,text,uuid,uuid) TO service_role;
GRANT EXECUTE ON FUNCTION henvalt.post_recovery_to_ledger_and_measure_billing_fenced(uuid,text,uuid,uuid) TO service_role;
GRANT EXECUTE ON FUNCTION henvalt.defer_payment_webhook_reconciliation_fenced(uuid,text,uuid,uuid,text) TO service_role;

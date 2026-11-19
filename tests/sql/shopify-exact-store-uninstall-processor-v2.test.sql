-- Structural PostgreSQL integration contract for exact-store app/uninstalled processing.
-- The trigger is inspected without inserting a fake verified webhook or mutating store state.
DO $test$
DECLARE
  v_function text;
  v_trigger record;
  v_trigger_def text;
BEGIN
  SELECT pg_catalog.pg_get_functiondef('henvalt.process_shopify_uninstall_receipt_v2()'::regprocedure)
    INTO v_function;

  IF v_function IS NULL
    OR position('NEW.connection_id' in v_function)=0
    OR position('NEW.tenant_id' in v_function)=0
    OR position('NEW.app_key' in v_function)=0
    OR position('NEW.shop_domain_header' in v_function)=0 THEN
    RAISE EXCEPTION 'Uninstall processor is missing exact connection lineage guards';
  END IF;

  IF position('SET active = false' in v_function)=0
    OR position('revoked_at = COALESCE(revoked_at' in v_function)=0
    OR position('DELETE FROM henvalt.shopify_delivery_permits_v2' in v_function)=0
    OR position('status = ''CANCELLED''' in v_function)=0
    OR position('status = ''CLOSED''' in v_function)=0 THEN
    RAISE EXCEPTION 'Uninstall processor does not close the expected install-scoped work';
  END IF;

  IF position('READY_FOR_AUTHORIZATION' in v_function)=0
    OR position('NOT EXISTS' in v_function)=0
    OR position('shopify_recovery_send_attempt_v2' in v_function)=0 THEN
    RAISE EXCEPTION 'Uninstall processor may cancel an intervention with a consumed/in-flight attempt';
  END IF;

  IF position('DELETE FROM henvalt.shopify_recovery_send_attempt_v2' in v_function)>0
    OR position('DELETE FROM henvalt.shopify_pixel_send_attempts_v2' in v_function)>0
    OR position('UPDATE henvalt.shopify_recovery_send_attempt_v2' in v_function)>0
    OR position('UPDATE henvalt.shopify_pixel_send_attempts_v2' in v_function)>0 THEN
    RAISE EXCEPTION 'Uninstall processor must preserve attempt history and in-flight outcomes';
  END IF;

  SELECT t.tgfoid::regprocedure::text AS function_name,
         t.tgtype,
         pg_catalog.pg_get_triggerdef(t.oid) AS definition
    INTO v_trigger
  FROM pg_catalog.pg_trigger t
  JOIN pg_catalog.pg_class c ON c.oid=t.tgrelid
  JOIN pg_catalog.pg_namespace n ON n.oid=c.relnamespace
  WHERE n.nspname='henvalt'
    AND c.relname='shopify_webhook_deliveries'
    AND t.tgname='shopify_exact_store_uninstall_after_receipt_v2'
    AND NOT t.tgisinternal;

  IF NOT FOUND OR v_trigger.function_name<>'henvalt.process_shopify_uninstall_receipt_v2()'
    OR position('AFTER INSERT' in v_trigger.definition)=0
    OR position('app/uninstalled' in v_trigger.definition)=0 THEN
    RAISE EXCEPTION 'Exact-store uninstall trigger is not attached to verified receipt insertion';
  END IF;

  IF has_function_privilege('anon','henvalt.process_shopify_uninstall_receipt_v2()','EXECUTE')
    OR has_function_privilege('authenticated','henvalt.process_shopify_uninstall_receipt_v2()','EXECUTE')
    OR has_function_privilege('service_role','henvalt.process_shopify_uninstall_receipt_v2()','EXECUTE') THEN
    RAISE EXCEPTION 'Uninstall trigger function must not be directly executable';
  END IF;
END;
$test$;
SELECT 'shopify_exact_store_uninstall_processor_contract_passed' AS result;

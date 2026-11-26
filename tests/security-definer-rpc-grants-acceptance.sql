DO $$
DECLARE
  v_total integer;
  v_public integer;
  v_anon integer;
  v_authenticated integer;
  v_service integer;
BEGIN
  SELECT count(*),
         count(*) FILTER (WHERE EXISTS (SELECT 1 FROM aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a WHERE a.grantee = 0 AND a.privilege_type = 'EXECUTE')),
         count(*) FILTER (WHERE has_function_privilege('anon', p.oid, 'EXECUTE')),
         count(*) FILTER (WHERE has_function_privilege('authenticated', p.oid, 'EXECUTE')),
         count(*) FILTER (WHERE has_function_privilege('service_role', p.oid, 'EXECUTE'))
    INTO v_total, v_public, v_anon, v_authenticated, v_service
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'henvalt' AND p.prokind = 'f' AND p.prosecdef;
  IF v_total <> v_service OR v_public <> 0 OR v_anon <> 0 OR v_authenticated <> 1 THEN
    RAISE EXCEPTION 'SECURITY DEFINER grant policy mismatch: total %, public %, anon %, authenticated %, service_role %',
      v_total, v_public, v_anon, v_authenticated, v_service;
  END IF;
  IF NOT has_function_privilege('authenticated', 'henvalt.is_tenant_member(uuid)', 'EXECUTE') THEN
    RAISE EXCEPTION 'authenticated RLS helper grant missing';
  END IF;
  IF has_function_privilege('anon', 'henvalt.is_tenant_member(uuid)', 'EXECUTE') THEN
    RAISE EXCEPTION 'anon must not execute tenant membership helper';
  END IF;
  IF has_function_privilege('anon', 'henvalt.classify_customer_reply_intent(text)', 'EXECUTE')
     OR has_function_privilege('authenticated', 'henvalt.classify_customer_reply_intent(text)', 'EXECUTE')
     OR NOT has_function_privilege('service_role', 'henvalt.classify_customer_reply_intent(text)', 'EXECUTE') THEN
    RAISE EXCEPTION 'classify_customer_reply_intent grant boundary failed';
  END IF;
  IF has_function_privilege('anon', 'henvalt.score_recovery_intent(uuid,uuid)', 'EXECUTE')
     OR has_function_privilege('authenticated', 'henvalt.score_recovery_intent(uuid,uuid)', 'EXECUTE')
     OR NOT has_function_privilege('service_role', 'henvalt.score_recovery_intent(uuid,uuid)', 'EXECUTE') THEN
    RAISE EXCEPTION 'score_recovery_intent grant boundary failed';
  END IF;
  IF has_function_privilege('anon', 'henvalt.set_initial_customer_reply_intent()', 'EXECUTE')
     OR has_function_privilege('authenticated', 'henvalt.set_initial_customer_reply_intent()', 'EXECUTE') THEN
    RAISE EXCEPTION 'trigger-only helper must not be directly executable by clients';
  END IF;
END $$;

CREATE OR REPLACE FUNCTION henvalt.default_acl_probe()
RETURNS integer LANGUAGE sql SECURITY DEFINER AS $$ SELECT 1 $$;
DO $$
BEGIN
  IF has_function_privilege('anon', 'henvalt.default_acl_probe()', 'EXECUTE')
     OR has_function_privilege('authenticated', 'henvalt.default_acl_probe()', 'EXECUTE')
     OR NOT has_function_privilege('service_role', 'henvalt.default_acl_probe()', 'EXECUTE') THEN
    RAISE EXCEPTION 'future SECURITY DEFINER function default ACL is unsafe';
  END IF;
END $$;
DROP FUNCTION henvalt.default_acl_probe();

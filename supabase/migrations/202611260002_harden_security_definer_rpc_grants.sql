-- Match the production RPC privilege model and prevent future SECURITY DEFINER
-- functions created by postgres in henvalt from inheriting PUBLIC EXECUTE.
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA henvalt
  REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC, anon, authenticated;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA henvalt
  GRANT EXECUTE ON FUNCTIONS TO service_role;

DO $$
DECLARE
  fn record;
BEGIN
  FOR fn IN
    SELECT p.oid::regprocedure AS signature
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'henvalt'
      AND p.prokind = 'f'
      AND p.prosecdef
  LOOP
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC, anon, authenticated', fn.signature);
    EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO service_role', fn.signature);
  END LOOP;
END
$$;

-- Used by authenticated RLS policies; this is the sole SECURITY DEFINER client RPC
-- in the production ACL baseline.
GRANT EXECUTE ON FUNCTION henvalt.is_tenant_member(uuid) TO authenticated;

-- Internal candidate helpers are not direct client APIs.
REVOKE ALL ON FUNCTION henvalt.classify_customer_reply_intent(text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION henvalt.score_recovery_intent(uuid, uuid) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION henvalt.set_initial_customer_reply_intent() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION henvalt.classify_customer_reply_intent(text) TO service_role;
GRANT EXECUTE ON FUNCTION henvalt.score_recovery_intent(uuid, uuid) TO service_role;

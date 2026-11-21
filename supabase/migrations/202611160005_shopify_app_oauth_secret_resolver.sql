-- Resolve the active Shopify app identity and its Vault-held OAuth/webhook secret.
-- PREPARATION ONLY. Depends on migration 001; no app rows are seeded here.
-- The returned secret is visible only to service_role callers (the Edge Function).

BEGIN;

CREATE OR REPLACE FUNCTION henvalt.resolve_shopify_app_oauth_identity(
  p_shopify_client_id text
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'pg_catalog', 'henvalt', 'vault', 'pg_temp'
AS $function$
DECLARE
  v_app henvalt.shopify_app_registry%rowtype;
  v_secret text;
BEGIN
  IF NULLIF(btrim(p_shopify_client_id), '') IS NULL THEN
    RAISE EXCEPTION 'shopify_client_id_required' USING ERRCODE = '22023';
  END IF;

  SELECT * INTO v_app
  FROM henvalt.shopify_app_registry
  WHERE shopify_client_id = p_shopify_client_id
    AND lifecycle_status = 'active';

  IF NOT FOUND THEN
    RAISE EXCEPTION 'shopify_app_identity_not_active'
      USING ERRCODE = '42501';
  END IF;

  SELECT decrypted_secret INTO v_secret
  FROM vault.decrypted_secrets
  WHERE name = v_app.webhook_secret_ref
     OR id::text = v_app.webhook_secret_ref
  LIMIT 1;

  IF v_secret IS NULL OR v_secret = '' THEN
    RAISE EXCEPTION 'shopify_app_secret_unavailable'
      USING ERRCODE = '55000';
  END IF;

  RETURN jsonb_build_object(
    'app_key', v_app.app_key,
    'shopify_client_id', v_app.shopify_client_id,
    'shopify_api_secret', v_secret
  );
END;
$function$;

REVOKE ALL ON FUNCTION henvalt.resolve_shopify_app_oauth_identity(text)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION henvalt.resolve_shopify_app_oauth_identity(text)
  TO service_role;

COMMENT ON FUNCTION henvalt.resolve_shopify_app_oauth_identity(text) IS
  'Service-role-only app identity resolver. Returns the active app secret to trusted server-side Edge Functions; never expose or log its result.';

COMMIT;

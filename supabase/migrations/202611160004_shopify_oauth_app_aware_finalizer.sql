-- App-aware OAuth finalization and one-time route-token provisioning.
-- PREPARATION ONLY. Depends on migrations 001 and 003. Do not apply until
-- reviewed and tested in a disposable Supabase/Postgres environment.
--
-- The Edge Function resolves app_key from its configured client ID and creates
-- a 256-bit route token in memory. This RPC independently verifies that
-- client-ID/app-key/state binding, delegates token persistence to the existing
-- finalizer inside the same transaction, binds the exact connection, and
-- stores only SHA-256(route_token).

BEGIN;

CREATE OR REPLACE FUNCTION henvalt.control_plane_finalize_shopify_oauth_install_app_aware(
  p_state_hash text,
  p_shop_domain text,
  p_access_token text,
  p_refresh_token text,
  p_access_expires_in integer,
  p_refresh_expires_in integer,
  p_shopify_shop_id text,
  p_scopes text[],
  p_user_id uuid,
  p_app_key text,
  p_shopify_client_id text,
  p_route_token text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'pg_catalog', 'public', 'henvalt', 'vault', 'extensions', 'pg_temp'
AS $function$
DECLARE
  v_state henvalt.shopify_oauth_states%rowtype;
  v_app henvalt.shopify_app_registry%rowtype;
  v_finalized jsonb;
  v_connection_id uuid;
  v_tenant_id uuid;
  v_existing_app_key text;
  v_token_hash text;
  v_rows integer;
BEGIN
  IF p_user_id IS NULL
     OR NULLIF(p_state_hash, '') IS NULL
     OR NULLIF(p_app_key, '') IS NULL
     OR NULLIF(p_shopify_client_id, '') IS NULL
     OR NULLIF(p_route_token, '') IS NULL
     OR p_route_token !~ '^[0-9a-f]{64}
  END IF;

  IF lower(p_shop_domain) !~ '^[a-z0-9][a-z0-9-]*[.]myshopify[.]com$'
     OR p_shop_domain <> lower(p_shop_domain) THEN
    RAISE EXCEPTION 'invalid_shop_domain' USING ERRCODE = '22023';
  END IF;

  -- Serialize all app-aware installations for this shop using the same
  -- advisory-lock key as the legacy connection resolver.
  PERFORM pg_advisory_xact_lock(hashtextextended(p_shop_domain, 0));

  SELECT * INTO v_state
  FROM henvalt.shopify_oauth_states
  WHERE state_hash = p_state_hash
  FOR UPDATE;

  IF NOT FOUND
     OR v_state.shop_domain <> p_shop_domain
     OR v_state.initiated_by_user_id IS DISTINCT FROM p_user_id
     OR v_state.expires_at <= now()
     OR v_state.consumed_at IS NOT NULL
     OR v_state.app_key IS DISTINCT FROM p_app_key THEN
    RAISE EXCEPTION 'invalid_or_expired_app_aware_oauth_state'
      USING ERRCODE = '42501';
  END IF;

  SELECT * INTO v_app
  FROM henvalt.shopify_app_registry
  WHERE app_key = p_app_key
    AND shopify_client_id = p_shopify_client_id
    AND lifecycle_status = 'active'
  FOR SHARE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'shopify_app_identity_not_active_or_mismatched'
      USING ERRCODE = '42501';
  END IF;

  SELECT app_key INTO v_existing_app_key
  FROM henvalt.shopify_connections
  WHERE lower(shop_domain) = p_shop_domain
  FOR UPDATE;

  IF FOUND AND v_existing_app_key IS NOT NULL
     AND v_existing_app_key <> p_app_key THEN
    RAISE EXCEPTION 'shopify_connection_bound_to_different_app'
      USING ERRCODE = '42501';
  END IF;

  -- The legacy finalizer performs the established token-vault writes,
  -- membership/audit work, and state consumption. All changes remain in this
  -- transaction and roll back if the following identity/token steps fail.
  v_finalized :=
    henvalt.control_plane_finalize_shopify_oauth_install_expiring_for_owner(
      p_state_hash,
      p_shop_domain,
      p_access_token,
      p_refresh_token,
      p_access_expires_in,
      p_refresh_expires_in,
      p_shopify_shop_id,
      p_scopes,
      p_user_id
    );

  v_connection_id := (v_finalized->>'connection_id')::uuid;
  v_tenant_id := (v_finalized->>'tenant_id')::uuid;

  UPDATE henvalt.shopify_connections
  SET app_key = p_app_key,
      updated_at = now()
  WHERE id = v_connection_id
    AND tenant_id = v_tenant_id
    AND (app_key IS NULL OR app_key = p_app_key);

  GET DIAGNOSTICS v_rows = ROW_COUNT;
  IF v_rows <> 1 THEN
    RAISE EXCEPTION 'shopify_connection_app_binding_failed'
      USING ERRCODE = '42501';
  END IF;

  v_token_hash := encode(
    extensions.digest(convert_to(p_route_token, 'UTF8'), 'sha256'),
    'hex'
  );

  INSERT INTO henvalt.shopify_webhook_route_tokens (
    tenant_id, connection_id, app_key, token_hash
  )
  VALUES (v_tenant_id, v_connection_id, p_app_key, v_token_hash)
  ON CONFLICT (token_hash) DO NOTHING;

  GET DIAGNOSTICS v_rows = ROW_COUNT;
  IF v_rows <> 1 THEN
    RAISE EXCEPTION 'shopify_webhook_route_token_collision'
      USING ERRCODE = '23505';
  END IF;

  RETURN v_finalized || jsonb_build_object(
    'app_key', p_app_key,
    'webhook_route_ready', true
  );
END;
$function$;

REVOKE ALL ON FUNCTION henvalt.control_plane_finalize_shopify_oauth_install_app_aware(
  text,text,text,text,integer,integer,text,text[],uuid,text,text,text
) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION henvalt.control_plane_finalize_shopify_oauth_install_app_aware(
  text,text,text,text,integer,integer,text,text[],uuid,text,text,text
) TO service_role;

COMMIT;
 THEN
    RAISE EXCEPTION 'invalid_app_aware_oauth_request' USING ERRCODE = '22023';
  END IF;

  IF lower(p_shop_domain) !~ '^[a-z0-9][a-z0-9-]*[.]myshopify[.]com$'
     OR p_shop_domain <> lower(p_shop_domain) THEN
    RAISE EXCEPTION 'invalid_shop_domain' USING ERRCODE = '22023';
  END IF;

  -- Serialize all app-aware installations for this shop using the same
  -- advisory-lock key as the legacy connection resolver.
  PERFORM pg_advisory_xact_lock(hashtextextended(p_shop_domain, 0));

  SELECT * INTO v_state
  FROM henvalt.shopify_oauth_states
  WHERE state_hash = p_state_hash
  FOR UPDATE;

  IF NOT FOUND
     OR v_state.shop_domain <> p_shop_domain
     OR v_state.initiated_by_user_id IS DISTINCT FROM p_user_id
     OR v_state.expires_at <= now()
     OR v_state.consumed_at IS NOT NULL
     OR v_state.app_key IS DISTINCT FROM p_app_key THEN
    RAISE EXCEPTION 'invalid_or_expired_app_aware_oauth_state'
      USING ERRCODE = '42501';
  END IF;

  SELECT * INTO v_app
  FROM henvalt.shopify_app_registry
  WHERE app_key = p_app_key
    AND shopify_client_id = p_shopify_client_id
    AND lifecycle_status = 'active'
  FOR SHARE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'shopify_app_identity_not_active_or_mismatched'
      USING ERRCODE = '42501';
  END IF;

  SELECT app_key INTO v_existing_app_key
  FROM henvalt.shopify_connections
  WHERE lower(shop_domain) = p_shop_domain
  FOR UPDATE;

  IF FOUND AND v_existing_app_key IS NOT NULL
     AND v_existing_app_key <> p_app_key THEN
    RAISE EXCEPTION 'shopify_connection_bound_to_different_app'
      USING ERRCODE = '42501';
  END IF;

  -- The legacy finalizer performs the established token-vault writes,
  -- membership/audit work, and state consumption. All changes remain in this
  -- transaction and roll back if the following identity/token steps fail.
  v_finalized :=
    henvalt.control_plane_finalize_shopify_oauth_install_expiring_for_owner(
      p_state_hash,
      p_shop_domain,
      p_access_token,
      p_refresh_token,
      p_access_expires_in,
      p_refresh_expires_in,
      p_shopify_shop_id,
      p_scopes,
      p_user_id
    );

  v_connection_id := (v_finalized->>'connection_id')::uuid;
  v_tenant_id := (v_finalized->>'tenant_id')::uuid;

  UPDATE henvalt.shopify_connections
  SET app_key = p_app_key,
      updated_at = now()
  WHERE id = v_connection_id
    AND tenant_id = v_tenant_id
    AND (app_key IS NULL OR app_key = p_app_key);

  GET DIAGNOSTICS v_rows = ROW_COUNT;
  IF v_rows <> 1 THEN
    RAISE EXCEPTION 'shopify_connection_app_binding_failed'
      USING ERRCODE = '42501';
  END IF;

  v_token_hash := encode(
    extensions.digest(convert_to(p_route_token, 'UTF8'), 'sha256'),
    'hex'
  );

  INSERT INTO henvalt.shopify_webhook_route_tokens (
    tenant_id, connection_id, app_key, token_hash
  )
  VALUES (v_tenant_id, v_connection_id, p_app_key, v_token_hash)
  ON CONFLICT (token_hash) DO NOTHING;

  GET DIAGNOSTICS v_rows = ROW_COUNT;
  IF v_rows <> 1 THEN
    RAISE EXCEPTION 'shopify_webhook_route_token_collision'
      USING ERRCODE = '23505';
  END IF;

  RETURN v_finalized || jsonb_build_object(
    'app_key', p_app_key,
    'webhook_route_ready', true
  );
END;
$function$;

REVOKE ALL ON FUNCTION henvalt.control_plane_finalize_shopify_oauth_install_app_aware(
  text,text,text,text,integer,integer,text,text[],uuid,text,text,text
) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION henvalt.control_plane_finalize_shopify_oauth_install_app_aware(
  text,text,text,text,integer,integer,text,text[],uuid,text,text,text
) TO service_role;

COMMIT;
 THEN
    RAISE EXCEPTION 'invalid_app_aware_oauth_request' USING ERRCODE = '22023';
  END IF;

  IF lower(p_shop_domain) !~ '^[a-z0-9][a-z0-9-]*[.]myshopify[.]com$'
     OR p_shop_domain <> lower(p_shop_domain) THEN
    RAISE EXCEPTION 'invalid_shop_domain' USING ERRCODE = '22023';
  END IF;

  -- Serialize all app-aware installations for this shop using the same
  -- advisory-lock key as the legacy connection resolver.
  PERFORM pg_advisory_xact_lock(hashtextextended(p_shop_domain, 0));

  SELECT * INTO v_state
  FROM henvalt.shopify_oauth_states
  WHERE state_hash = p_state_hash
  FOR UPDATE;

  IF NOT FOUND
     OR v_state.shop_domain <> p_shop_domain
     OR v_state.initiated_by_user_id IS DISTINCT FROM p_user_id
     OR v_state.expires_at <= now()
     OR v_state.consumed_at IS NOT NULL
     OR v_state.app_key IS DISTINCT FROM p_app_key THEN
    RAISE EXCEPTION 'invalid_or_expired_app_aware_oauth_state'
      USING ERRCODE = '42501';
  END IF;

  SELECT * INTO v_app
  FROM henvalt.shopify_app_registry
  WHERE app_key = p_app_key
    AND shopify_client_id = p_shopify_client_id
    AND lifecycle_status = 'active'
  FOR SHARE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'shopify_app_identity_not_active_or_mismatched'
      USING ERRCODE = '42501';
  END IF;

  SELECT app_key INTO v_existing_app_key
  FROM henvalt.shopify_connections
  WHERE lower(shop_domain) = p_shop_domain
  FOR UPDATE;

  IF FOUND AND v_existing_app_key IS NOT NULL
     AND v_existing_app_key <> p_app_key THEN
    RAISE EXCEPTION 'shopify_connection_bound_to_different_app'
      USING ERRCODE = '42501';
  END IF;

  -- The legacy finalizer performs the established token-vault writes,
  -- membership/audit work, and state consumption. All changes remain in this
  -- transaction and roll back if the following identity/token steps fail.
  v_finalized :=
    henvalt.control_plane_finalize_shopify_oauth_install_expiring_for_owner(
      p_state_hash,
      p_shop_domain,
      p_access_token,
      p_refresh_token,
      p_access_expires_in,
      p_refresh_expires_in,
      p_shopify_shop_id,
      p_scopes,
      p_user_id
    );

  v_connection_id := (v_finalized->>'connection_id')::uuid;
  v_tenant_id := (v_finalized->>'tenant_id')::uuid;

  UPDATE henvalt.shopify_connections
  SET app_key = p_app_key,
      updated_at = now()
  WHERE id = v_connection_id
    AND tenant_id = v_tenant_id
    AND (app_key IS NULL OR app_key = p_app_key);

  GET DIAGNOSTICS v_rows = ROW_COUNT;
  IF v_rows <> 1 THEN
    RAISE EXCEPTION 'shopify_connection_app_binding_failed'
      USING ERRCODE = '42501';
  END IF;

  v_token_hash := encode(
    extensions.digest(convert_to(p_route_token, 'UTF8'), 'sha256'),
    'hex'
  );

  INSERT INTO henvalt.shopify_webhook_route_tokens (
    tenant_id, connection_id, app_key, token_hash
  )
  VALUES (v_tenant_id, v_connection_id, p_app_key, v_token_hash)
  ON CONFLICT (token_hash) DO NOTHING;

  GET DIAGNOSTICS v_rows = ROW_COUNT;
  IF v_rows <> 1 THEN
    RAISE EXCEPTION 'shopify_webhook_route_token_collision'
      USING ERRCODE = '23505';
  END IF;

  RETURN v_finalized || jsonb_build_object(
    'app_key', p_app_key,
    'webhook_route_ready', true
  );
END;
$function$;

REVOKE ALL ON FUNCTION henvalt.control_plane_finalize_shopify_oauth_install_app_aware(
  text,text,text,text,integer,integer,text,text[],uuid,text,text,text
) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION henvalt.control_plane_finalize_shopify_oauth_install_app_aware(
  text,text,text,text,integer,integer,text,text[],uuid,text,text,text
) TO service_role;

COMMIT;
 THEN
    RAISE EXCEPTION 'invalid_app_aware_oauth_request' USING ERRCODE = '22023';
  END IF;

  IF lower(p_shop_domain) !~ '^[a-z0-9][a-z0-9-]*[.]myshopify[.]com$'
     OR p_shop_domain <> lower(p_shop_domain) THEN
    RAISE EXCEPTION 'invalid_shop_domain' USING ERRCODE = '22023';
  END IF;

  -- Serialize all app-aware installations for this shop using the same
  -- advisory-lock key as the legacy connection resolver.
  PERFORM pg_advisory_xact_lock(hashtextextended(p_shop_domain, 0));

  SELECT * INTO v_state
  FROM henvalt.shopify_oauth_states
  WHERE state_hash = p_state_hash
  FOR UPDATE;

  IF NOT FOUND
     OR v_state.shop_domain <> p_shop_domain
     OR v_state.initiated_by_user_id IS DISTINCT FROM p_user_id
     OR v_state.expires_at <= now()
     OR v_state.consumed_at IS NOT NULL
     OR v_state.app_key IS DISTINCT FROM p_app_key THEN
    RAISE EXCEPTION 'invalid_or_expired_app_aware_oauth_state'
      USING ERRCODE = '42501';
  END IF;

  SELECT * INTO v_app
  FROM henvalt.shopify_app_registry
  WHERE app_key = p_app_key
    AND shopify_client_id = p_shopify_client_id
    AND lifecycle_status = 'active'
  FOR SHARE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'shopify_app_identity_not_active_or_mismatched'
      USING ERRCODE = '42501';
  END IF;

  SELECT app_key INTO v_existing_app_key
  FROM henvalt.shopify_connections
  WHERE lower(shop_domain) = p_shop_domain
  FOR UPDATE;

  IF FOUND AND v_existing_app_key IS NOT NULL
     AND v_existing_app_key <> p_app_key THEN
    RAISE EXCEPTION 'shopify_connection_bound_to_different_app'
      USING ERRCODE = '42501';
  END IF;

  -- The legacy finalizer performs the established token-vault writes,
  -- membership/audit work, and state consumption. All changes remain in this
  -- transaction and roll back if the following identity/token steps fail.
  v_finalized :=
    henvalt.control_plane_finalize_shopify_oauth_install_expiring_for_owner(
      p_state_hash,
      p_shop_domain,
      p_access_token,
      p_refresh_token,
      p_access_expires_in,
      p_refresh_expires_in,
      p_shopify_shop_id,
      p_scopes,
      p_user_id
    );

  v_connection_id := (v_finalized->>'connection_id')::uuid;
  v_tenant_id := (v_finalized->>'tenant_id')::uuid;

  UPDATE henvalt.shopify_connections
  SET app_key = p_app_key,
      updated_at = now()
  WHERE id = v_connection_id
    AND tenant_id = v_tenant_id
    AND (app_key IS NULL OR app_key = p_app_key);

  GET DIAGNOSTICS v_rows = ROW_COUNT;
  IF v_rows <> 1 THEN
    RAISE EXCEPTION 'shopify_connection_app_binding_failed'
      USING ERRCODE = '42501';
  END IF;

  v_token_hash := encode(
    extensions.digest(convert_to(p_route_token, 'UTF8'), 'sha256'),
    'hex'
  );

  INSERT INTO henvalt.shopify_webhook_route_tokens (
    tenant_id, connection_id, app_key, token_hash
  )
  VALUES (v_tenant_id, v_connection_id, p_app_key, v_token_hash)
  ON CONFLICT (token_hash) DO NOTHING;

  GET DIAGNOSTICS v_rows = ROW_COUNT;
  IF v_rows <> 1 THEN
    RAISE EXCEPTION 'shopify_webhook_route_token_collision'
      USING ERRCODE = '23505';
  END IF;

  RETURN v_finalized || jsonb_build_object(
    'app_key', p_app_key,
    'webhook_route_ready', true
  );
END;
$function$;

REVOKE ALL ON FUNCTION henvalt.control_plane_finalize_shopify_oauth_install_app_aware(
  text,text,text,text,integer,integer,text,text[],uuid,text,text,text
) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION henvalt.control_plane_finalize_shopify_oauth_install_app_aware(
  text,text,text,text,integer,integer,text,text[],uuid,text,text,text
) TO service_role;

COMMIT;

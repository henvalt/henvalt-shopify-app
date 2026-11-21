-- Align the database token-refresh claim window with HENVALT_RECOVERY's
-- ten-minute due-token query so the worker does not poll and receive TOKEN_STILL_VALID
-- for five consecutive minutes before a refresh can be claimed.
-- Candidate migration only; do not apply to production without staging validation.
BEGIN;

CREATE OR REPLACE FUNCTION henvalt.claim_shopify_token_refresh(p_shop_domain text, p_force boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO pg_catalog, henvalt, vault, pg_temp
AS $function$
declare v_conn henvalt.shopify_connections%rowtype; v_refresh_token text;
begin
  if coalesce(auth.jwt()->>'role', current_setting('request.jwt.claim.role', true)) is distinct from 'service_role' then
    raise exception 'service_role_required' using errcode='42501';
  end if;
  if p_shop_domain is null or p_shop_domain !~ '^[a-z0-9][a-z0-9-]*\.myshopify\.com$' then
    raise exception 'invalid_shop_domain' using errcode='22023';
  end if;
  perform pg_advisory_xact_lock(hashtextextended(lower(p_shop_domain)||':shopify-token-refresh',0));
  select * into v_conn from henvalt.shopify_connections
    where lower(shop_domain)=lower(p_shop_domain) and active=true limit 1 for update;
  if not found then return jsonb_build_object('claimed',false,'reason','CONNECTION_NOT_FOUND'); end if;
  if v_conn.token_type <> 'offline_expiring' or v_conn.refresh_token_secret_ref is null
     or v_conn.refresh_token_secret_ref !~* '^[0-9a-f-]{36}$' then
    return jsonb_build_object('claimed',false,'reason','EXPIRING_OFFLINE_TOKEN_NOT_CONFIGURED');
  end if;
  if v_conn.reauth_required_at is not null then return jsonb_build_object('claimed',false,'reason','REAUTH_REQUIRED'); end if;
  if not p_force and v_conn.access_token_expires_at > now()+interval '10 minutes' then
    return jsonb_build_object('claimed',false,'reason','TOKEN_STILL_VALID','expires_at',v_conn.access_token_expires_at);
  end if;
  if v_conn.token_refresh_lease_until is not null and v_conn.token_refresh_lease_until>now() then
    return jsonb_build_object('claimed',false,'reason','REFRESH_ALREADY_IN_PROGRESS');
  end if;
  if v_conn.refresh_token_expires_at is not null and v_conn.refresh_token_expires_at<=now() then
    update henvalt.shopify_connections set reauth_required_at=now(),token_refresh_last_error='refresh_token_expired',
      token_refresh_lease_until=null,updated_at=now() where id=v_conn.id;
    return jsonb_build_object('claimed',false,'reason','REAUTH_REQUIRED');
  end if;
  select decrypted_secret into v_refresh_token from vault.decrypted_secrets where id=v_conn.refresh_token_secret_ref::uuid;
  if v_refresh_token is null then
    update henvalt.shopify_connections set token_refresh_last_error='refresh_secret_unavailable',
      token_refresh_lease_until=null,updated_at=now() where id=v_conn.id;
    return jsonb_build_object('claimed',false,'reason','REFRESH_SECRET_UNAVAILABLE');
  end if;
  update henvalt.shopify_connections set token_refresh_lease_until=now()+interval '90 seconds',
    token_refresh_started_at=now(),updated_at=now() where id=v_conn.id;
  return jsonb_build_object('claimed',true,'shop_domain',v_conn.shop_domain,
    'refresh_token',v_refresh_token);
end;
$function$
;

COMMIT;

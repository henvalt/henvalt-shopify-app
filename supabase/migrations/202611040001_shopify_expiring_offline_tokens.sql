alter table henvalt.shopify_connections
  add column if not exists refresh_token_secret_ref text,
  add column if not exists access_token_expires_at timestamptz,
  add column if not exists refresh_token_expires_at timestamptz,
  add column if not exists token_type text,
  add column if not exists token_updated_at timestamptz;

create or replace function henvalt.control_plane_finalize_shopify_oauth_install_expiring_for_owner(
  p_state_hash text, p_shop_domain text, p_access_token text, p_refresh_token text,
  p_access_expires_in integer, p_refresh_expires_in integer,
  p_shopify_shop_id text, p_scopes text[], p_user_id uuid
) returns jsonb
language plpgsql security definer
set search_path = pg_catalog, public, henvalt, vault
as $function$
declare
  v_state henvalt.shopify_oauth_states%rowtype;
  v_tenant_id uuid;
  v_connection_id uuid;
  v_connection jsonb;
  v_access_ref text;
  v_refresh_ref text;
  v_secret_name text;
  v_access_secret_id uuid;
  v_refresh_secret_id uuid;
begin
  if p_user_id is null then raise exception 'authenticated_owner_required' using errcode = '42501'; end if;
  if p_access_token is null or length(p_access_token) < 20 or length(p_access_token) > 512
     or p_refresh_token is null or length(p_refresh_token) < 20 or length(p_refresh_token) > 1024
     or p_access_expires_in is null or p_access_expires_in < 60
     or p_refresh_expires_in is null or p_refresh_expires_in < p_access_expires_in then
    raise exception 'invalid_expiring_shopify_token_pair';
  end if;
  select * into v_state from henvalt.shopify_oauth_states where state_hash = p_state_hash for update;
  if not found or v_state.shop_domain <> p_shop_domain
     or v_state.initiated_by_user_id is distinct from p_user_id
     or v_state.expires_at <= now() or v_state.consumed_at is not null then
    raise exception 'invalid_or_expired_owner_oauth_state' using errcode = '42501';
  end if;
  select tenant_id into v_tenant_id from henvalt.shopify_connections
    where lower(shop_domain) = lower(p_shop_domain) limit 1;
  if v_tenant_id is not null and exists (select 1 from henvalt.tenant_memberships where tenant_id = v_tenant_id)
     and not exists (select 1 from henvalt.tenant_memberships where tenant_id = v_tenant_id and user_id = p_user_id) then
    raise exception 'tenant_already_claimed' using errcode = '42501';
  end if;
  v_connection := henvalt.control_plane_connect_shop(p_shop_domain);
  v_connection_id := (v_connection->>'connection_id')::uuid;
  v_tenant_id := (v_connection->>'tenant_id')::uuid;
  select access_token_secret_ref, refresh_token_secret_ref into v_access_ref, v_refresh_ref
    from henvalt.shopify_connections where id = v_connection_id for update;

  v_secret_name := 'henvalt_shopify_' || replace(p_shop_domain, '.', '_') || '_access';
  if v_access_ref ~* '^[0-9a-f-]{36}$' then
    begin v_access_secret_id := v_access_ref::uuid; perform 1 from vault.secrets where id = v_access_secret_id; if not found then v_access_secret_id := null; end if;
    exception when invalid_text_representation then v_access_secret_id := null; end;
  end if;
  if v_access_secret_id is null then select id into v_access_secret_id from vault.secrets where name = v_secret_name limit 1; end if;
  if v_access_secret_id is null then
    v_access_secret_id := vault.create_secret(p_access_token, v_secret_name, 'Shopify expiring Admin API access token for ' || p_shop_domain, null);
  else
    perform vault.update_secret(v_access_secret_id, p_access_token, v_secret_name, 'Shopify expiring Admin API access token for ' || p_shop_domain, null);
  end if;

  v_secret_name := 'henvalt_shopify_' || replace(p_shop_domain, '.', '_') || '_refresh';
  if v_refresh_ref ~* '^[0-9a-f-]{36}$' then
    begin v_refresh_secret_id := v_refresh_ref::uuid; perform 1 from vault.secrets where id = v_refresh_secret_id; if not found then v_refresh_secret_id := null; end if;
    exception when invalid_text_representation then v_refresh_secret_id := null; end;
  end if;
  if v_refresh_secret_id is null then select id into v_refresh_secret_id from vault.secrets where name = v_secret_name limit 1; end if;
  if v_refresh_secret_id is null then
    v_refresh_secret_id := vault.create_secret(p_refresh_token, v_secret_name, 'Shopify expiring Admin API refresh token for ' || p_shop_domain, null);
  else
    perform vault.update_secret(v_refresh_secret_id, p_refresh_token, v_secret_name, 'Shopify expiring Admin API refresh token for ' || p_shop_domain, null);
  end if;

  update henvalt.shopify_connections set shopify_shop_id = nullif(p_shopify_shop_id, ''),
    access_token_secret_ref = v_access_secret_id::text, refresh_token_secret_ref = v_refresh_secret_id::text,
    access_token_expires_at = now() + make_interval(secs => p_access_expires_in),
    refresh_token_expires_at = now() + make_interval(secs => p_refresh_expires_in),
    token_type = 'offline_expiring', token_updated_at = now(),
    scopes = coalesce(p_scopes, '{}'::text[]), active = true, updated_at = now()
    where id = v_connection_id;
  update henvalt.shopify_oauth_states set consumed_at = now() where state_hash = p_state_hash;
  insert into henvalt.tenant_memberships (tenant_id, user_id, role)
    values (v_tenant_id, p_user_id, 'OWNER'::henvalt.member_role) on conflict (tenant_id, user_id) do nothing;
  insert into henvalt.audit_log (tenant_id, event_name, entity_type, entity_id, actor_type, actor_reference, payload)
    values (v_tenant_id, 'SHOPIFY_OAUTH_INSTALL_COMPLETED', 'shopify_connection', v_connection_id, 'SYSTEM', p_shop_domain,
      jsonb_build_object('shop_domain', p_shop_domain, 'scopes', coalesce(p_scopes, '{}'::text[]),
        'token_type', 'offline_expiring', 'access_expires_in', p_access_expires_in, 'refresh_expires_in', p_refresh_expires_in));
  return jsonb_build_object('installed', true, 'shop_domain', p_shop_domain, 'tenant_id', v_tenant_id,
    'connection_id', v_connection_id, 'token_type', 'offline_expiring');
end;
$function$;

revoke all on function henvalt.control_plane_finalize_shopify_oauth_install_expiring_for_owner(text,text,text,text,integer,integer,text,text[],uuid) from public, anon, authenticated;
grant execute on function henvalt.control_plane_finalize_shopify_oauth_install_expiring_for_owner(text,text,text,text,integer,integer,text,text[],uuid) to service_role;

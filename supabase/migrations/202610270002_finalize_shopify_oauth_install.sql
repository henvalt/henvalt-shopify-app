-- Service-role-only OAuth finalization RPC. Token values are passed only to Vault, never returned.
create or replace function henvalt.control_plane_finalize_shopify_oauth_install(
  p_state_hash text, p_shop_domain text, p_access_token text, p_shopify_shop_id text, p_scopes text[]
) returns jsonb language plpgsql security definer
set search_path = pg_catalog, public, henvalt, vault
as $$
declare v_state henvalt.shopify_oauth_states%rowtype; v_connection jsonb; v_connection_id uuid; v_tenant_id uuid; v_secret_id uuid;
begin
  if p_shop_domain is null or p_shop_domain !~ '^[a-z0-9][a-z0-9-]*\.myshopify\.com$' then raise exception 'invalid_shop_domain'; end if;
  if p_access_token is null or length(p_access_token) < 20 or length(p_access_token) > 512 then raise exception 'invalid_access_token'; end if;
  if p_state_hash is null or length(p_state_hash) <> 64 then raise exception 'invalid_oauth_state'; end if;
  select * into v_state from henvalt.shopify_oauth_states where state_hash=p_state_hash for update;
  if not found or v_state.shop_domain<>p_shop_domain or v_state.expires_at<=now() or v_state.consumed_at is not null then raise exception 'invalid_or_expired_oauth_state'; end if;
  update henvalt.shopify_oauth_states set consumed_at=now() where state_hash=p_state_hash;
  v_connection:=henvalt.control_plane_connect_shop(p_shop_domain);
  v_connection_id:=(v_connection->>'connection_id')::uuid; v_tenant_id:=(v_connection->>'tenant_id')::uuid;
  v_secret_id:=vault.create_secret(p_access_token,'henvalt_shopify_'||replace(p_shop_domain,'.','_'),'Shopify Admin API access token for '||p_shop_domain,null);
  update henvalt.shopify_connections set shopify_shop_id=nullif(p_shopify_shop_id,''),access_token_secret_ref=v_secret_id::text,scopes=coalesce(p_scopes,'{}'::text[]),active=true,updated_at=now() where id=v_connection_id;
  insert into henvalt.audit_log(tenant_id,event_name,entity_type,entity_id,actor_type,actor_reference,payload)
  values(v_tenant_id,'SHOPIFY_OAUTH_INSTALL_COMPLETED','shopify_connection',v_connection_id,'SYSTEM',p_shop_domain,jsonb_build_object('shop_domain',p_shop_domain,'scopes',coalesce(p_scopes,'{}'::text[])));
  return jsonb_build_object('installed',true,'shop_domain',p_shop_domain,'tenant_id',v_tenant_id,'connection_id',v_connection_id);
end;
$$;
revoke all on function henvalt.control_plane_finalize_shopify_oauth_install(text,text,text,text,text[]) from public,anon,authenticated;
grant execute on function henvalt.control_plane_finalize_shopify_oauth_install(text,text,text,text,text[]) to service_role;

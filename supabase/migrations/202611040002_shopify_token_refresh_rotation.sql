
alter table henvalt.shopify_connections
  add column if not exists token_refresh_lease_until timestamptz,
  add column if not exists token_refresh_started_at timestamptz,
  add column if not exists token_refresh_last_error text,
  add column if not exists reauth_required_at timestamptz;

create or replace function henvalt.claim_shopify_token_refresh(p_shop_domain text, p_force boolean default false)
returns jsonb language plpgsql security definer
set search_path = pg_catalog, public, henvalt, vault
as $function$
declare v_conn henvalt.shopify_connections%rowtype; v_refresh_token text;
begin
  if current_setting('request.jwt.claim.role', true) <> 'service_role' then
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
  if not p_force and v_conn.access_token_expires_at > now()+interval '5 minutes' then
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
    'access_secret_ref',v_conn.access_token_secret_ref,'refresh_secret_ref',v_conn.refresh_token_secret_ref,
    'refresh_token',v_refresh_token);
end;
$function$;

create or replace function henvalt.complete_shopify_token_refresh(
 p_shop_domain text,p_access_token text,p_refresh_token text,p_access_expires_in integer,p_refresh_expires_in integer
) returns jsonb language plpgsql security definer
set search_path=pg_catalog,public,henvalt,vault
as $function$
declare v_conn henvalt.shopify_connections%rowtype;
begin
  if current_setting('request.jwt.claim.role',true)<>'service_role' then raise exception 'service_role_required' using errcode='42501'; end if;
  if p_access_token is null or length(p_access_token)<20 or length(p_access_token)>512
     or p_refresh_token is null or length(p_refresh_token)<20 or length(p_refresh_token)>1024
     or p_access_expires_in is null or p_access_expires_in<60
     or p_refresh_expires_in is null or p_refresh_expires_in<60 then
    raise exception 'invalid_refresh_response' using errcode='22023';
  end if;
  perform pg_advisory_xact_lock(hashtextextended(lower(p_shop_domain)||':shopify-token-refresh',0));
  select * into v_conn from henvalt.shopify_connections
    where lower(shop_domain)=lower(p_shop_domain) and active=true limit 1 for update;
  if not found or v_conn.token_type<>'offline_expiring'
     or v_conn.token_refresh_lease_until is null or v_conn.token_refresh_lease_until<=now() then
    raise exception 'refresh_lease_missing_or_expired' using errcode='42501';
  end if;
  perform vault.update_secret(v_conn.access_token_secret_ref::uuid,p_access_token,
    'henvalt_shopify_'||replace(v_conn.shop_domain,'.','_')||'_access',
    'Shopify expiring Admin API access token for '||v_conn.shop_domain);
  perform vault.update_secret(v_conn.refresh_token_secret_ref::uuid,p_refresh_token,
    'henvalt_shopify_'||replace(v_conn.shop_domain,'.','_')||'_refresh',
    'Shopify expiring Admin API refresh token for '||v_conn.shop_domain);
  update henvalt.shopify_connections set access_token_expires_at=now()+make_interval(secs=>p_access_expires_in),
    refresh_token_expires_at=now()+make_interval(secs=>p_refresh_expires_in),token_updated_at=now(),
    token_refresh_lease_until=null,token_refresh_last_error=null,reauth_required_at=null,updated_at=now()
    where id=v_conn.id;
  insert into henvalt.audit_log(tenant_id,event_name,entity_type,entity_id,actor_type,actor_reference,payload)
    values(v_conn.tenant_id,'SHOPIFY_OFFLINE_TOKEN_REFRESHED','shopify_connection',v_conn.id,'SYSTEM',
      v_conn.shop_domain,jsonb_build_object('access_expires_in',p_access_expires_in,'refresh_expires_in',p_refresh_expires_in));
  return jsonb_build_object('refreshed',true,'shop_domain',v_conn.shop_domain,
    'access_expires_at',now()+make_interval(secs=>p_access_expires_in),
    'refresh_expires_at',now()+make_interval(secs=>p_refresh_expires_in));
end;
$function$;

create or replace function henvalt.fail_shopify_token_refresh(p_shop_domain text,p_error_code text,p_reauth_required boolean default false)
returns jsonb language plpgsql security definer
set search_path=pg_catalog,public,henvalt
as $function$
declare v_id uuid;
begin
  if current_setting('request.jwt.claim.role',true)<>'service_role' then raise exception 'service_role_required' using errcode='42501'; end if;
  update henvalt.shopify_connections set token_refresh_lease_until=null,
    token_refresh_last_error=left(coalesce(p_error_code,'refresh_failed'),120),
    reauth_required_at=case when p_reauth_required then now() else reauth_required_at end,updated_at=now()
    where lower(shop_domain)=lower(p_shop_domain) and active=true returning id into v_id;
  return jsonb_build_object('recorded',v_id is not null,'reauth_required',p_reauth_required);
end;
$function$;

revoke all on function henvalt.claim_shopify_token_refresh(text,boolean) from public,anon,authenticated;
revoke all on function henvalt.complete_shopify_token_refresh(text,text,text,integer,integer) from public,anon,authenticated;
revoke all on function henvalt.fail_shopify_token_refresh(text,text,boolean) from public,anon,authenticated;
grant execute on function henvalt.claim_shopify_token_refresh(text,boolean) to service_role;
grant execute on function henvalt.complete_shopify_token_refresh(text,text,text,integer,integer) to service_role;
grant execute on function henvalt.fail_shopify_token_refresh(text,text,boolean) to service_role;

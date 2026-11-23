-- Fence every Shopify expiring-offline-token refresh attempt with an unguessable lease ID.
-- Additive to the already-live token storage/refresh schema; no credentials are changed.

alter table henvalt.shopify_connections
  add column if not exists token_refresh_lease_until timestamptz,
  add column if not exists token_refresh_started_at timestamptz,
  add column if not exists token_refresh_last_error text,
  add column if not exists token_refresh_lease_id uuid;

comment on column henvalt.shopify_connections.token_refresh_lease_id is
  'Unique owner token for the currently claimed Shopify refresh lease; stale workers cannot complete or fail a newer lease.';

create or replace function henvalt.claim_shopify_token_refresh(
  p_shop_domain text,
  p_force boolean default false
) returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public, henvalt, vault
as $function$
declare
  v_conn henvalt.shopify_connections%rowtype;
  v_refresh_token text;
  v_lease_id uuid;
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
  if not p_force and v_conn.access_token_expires_at > now()+interval '5 minutes' then
    return jsonb_build_object('claimed',false,'reason','TOKEN_STILL_VALID','expires_at',v_conn.access_token_expires_at);
  end if;
  if v_conn.token_refresh_lease_until is not null and v_conn.token_refresh_lease_until>now() then
    return jsonb_build_object('claimed',false,'reason','REFRESH_ALREADY_IN_PROGRESS');
  end if;
  if v_conn.refresh_token_expires_at is not null and v_conn.refresh_token_expires_at<=now() then
    update henvalt.shopify_connections set reauth_required_at=now(),token_refresh_last_error='refresh_token_expired',
      token_refresh_lease_until=null,token_refresh_lease_id=null,updated_at=now() where id=v_conn.id;
    return jsonb_build_object('claimed',false,'reason','REAUTH_REQUIRED');
  end if;

  select decrypted_secret into v_refresh_token from vault.decrypted_secrets where id=v_conn.refresh_token_secret_ref::uuid;
  if v_refresh_token is null then
    update henvalt.shopify_connections set token_refresh_last_error='refresh_secret_unavailable',
      token_refresh_lease_until=null,token_refresh_lease_id=null,updated_at=now() where id=v_conn.id;
    return jsonb_build_object('claimed',false,'reason','REFRESH_SECRET_UNAVAILABLE');
  end if;

  v_lease_id := gen_random_uuid();
  update henvalt.shopify_connections set
    token_refresh_lease_id=v_lease_id,
    token_refresh_lease_until=now()+interval '10 minutes',
    token_refresh_started_at=now(),
    updated_at=now()
    where id=v_conn.id;

  return jsonb_build_object(
    'claimed',true,
    'shop_domain',v_conn.shop_domain,
    'refresh_token',v_refresh_token,
    'lease_id',v_lease_id
  );
end;
$function$;

-- Remove the unfenced RPC signatures. The Edge Function is the only live caller.
drop function if exists henvalt.complete_shopify_token_refresh(text,text,text,integer,integer);
drop function if exists henvalt.fail_shopify_token_refresh(text,text,boolean);

create function henvalt.complete_shopify_token_refresh(
  p_shop_domain text,
  p_access_token text,
  p_refresh_token text,
  p_access_expires_in integer,
  p_refresh_expires_in integer,
  p_lease_id uuid
) returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public, henvalt, vault
as $function$
declare
  v_conn henvalt.shopify_connections%rowtype;
  v_access_expires_at timestamptz;
  v_refresh_expires_at timestamptz;
begin
  if coalesce(auth.jwt()->>'role', current_setting('request.jwt.claim.role', true)) is distinct from 'service_role' then
    raise exception 'service_role_required' using errcode='42501';
  end if;
  if p_lease_id is null then raise exception 'refresh_lease_id_required' using errcode='22023'; end if;
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
     or v_conn.token_refresh_lease_id is distinct from p_lease_id
     or v_conn.token_refresh_lease_until is null
     or v_conn.token_refresh_lease_until<=now() then
    return jsonb_build_object('refreshed',false,'reason','STALE_REFRESH_LEASE');
  end if;
  if v_conn.access_token_secret_ref is null or v_conn.access_token_secret_ref !~* '^[0-9a-f-]{36}$'
     or v_conn.refresh_token_secret_ref is null or v_conn.refresh_token_secret_ref !~* '^[0-9a-f-]{36}$' then
    raise exception 'token_secret_reference_invalid' using errcode='22023';
  end if;

  -- The pair and expiry timestamps are persisted inside one database transaction.
  perform vault.update_secret(v_conn.access_token_secret_ref::uuid,p_access_token,
    'henvalt_shopify_'||replace(v_conn.shop_domain,'.','_')||'_access',
    'Shopify expiring Admin API access token for '||v_conn.shop_domain);
  perform vault.update_secret(v_conn.refresh_token_secret_ref::uuid,p_refresh_token,
    'henvalt_shopify_'||replace(v_conn.shop_domain,'.','_')||'_refresh',
    'Shopify expiring Admin API refresh token for '||v_conn.shop_domain);

  v_access_expires_at := now()+make_interval(secs=>p_access_expires_in);
  v_refresh_expires_at := now()+make_interval(secs=>p_refresh_expires_in);
  update henvalt.shopify_connections set
    access_token_expires_at=v_access_expires_at,
    refresh_token_expires_at=v_refresh_expires_at,
    token_updated_at=now(),
    token_refresh_lease_until=null,
    token_refresh_lease_id=null,
    token_refresh_last_error=null,
    reauth_required_at=null,
    updated_at=now()
    where id=v_conn.id and token_refresh_lease_id=p_lease_id;

  insert into henvalt.audit_log(tenant_id,event_name,entity_type,entity_id,actor_type,actor_reference,payload)
    values(v_conn.tenant_id,'SHOPIFY_OFFLINE_TOKEN_REFRESHED','shopify_connection',v_conn.id,'SYSTEM',
      v_conn.shop_domain,jsonb_build_object('access_expires_in',p_access_expires_in,'refresh_expires_in',p_refresh_expires_in));

  return jsonb_build_object('refreshed',true,'shop_domain',v_conn.shop_domain,
    'access_expires_at',v_access_expires_at,'refresh_expires_at',v_refresh_expires_at);
end;
$function$;

create function henvalt.fail_shopify_token_refresh(
  p_shop_domain text,
  p_error_code text,
  p_reauth_required boolean,
  p_lease_id uuid
) returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public, henvalt
as $function$
declare
  v_id uuid;
begin
  if coalesce(auth.jwt()->>'role', current_setting('request.jwt.claim.role', true)) is distinct from 'service_role' then
    raise exception 'service_role_required' using errcode='42501';
  end if;
  if p_lease_id is null then raise exception 'refresh_lease_id_required' using errcode='22023'; end if;

  update henvalt.shopify_connections set
    token_refresh_lease_until=null,
    token_refresh_lease_id=null,
    token_refresh_last_error=left(coalesce(p_error_code,'refresh_failed'),120),
    reauth_required_at=case when p_reauth_required then now() else reauth_required_at end,
    updated_at=now()
    where lower(shop_domain)=lower(p_shop_domain)
      and active=true
      and token_refresh_lease_id=p_lease_id
      and token_refresh_lease_until>now()
    returning id into v_id;

  return jsonb_build_object(
    'recorded',v_id is not null,
    'reason',case when v_id is null then 'STALE_REFRESH_LEASE' else 'RECORDED' end,
    'reauth_required',case when v_id is not null then p_reauth_required else false end
  );
end;
$function$;

revoke all on function henvalt.claim_shopify_token_refresh(text,boolean) from public, anon, authenticated;
revoke all on function henvalt.complete_shopify_token_refresh(text,text,text,integer,integer,uuid) from public, anon, authenticated;
revoke all on function henvalt.fail_shopify_token_refresh(text,text,boolean,uuid) from public, anon, authenticated;
grant execute on function henvalt.claim_shopify_token_refresh(text,boolean) to service_role;
grant execute on function henvalt.complete_shopify_token_refresh(text,text,text,integer,integer,uuid) to service_role;
grant execute on function henvalt.fail_shopify_token_refresh(text,text,boolean,uuid) to service_role;

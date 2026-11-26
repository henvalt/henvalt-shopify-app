-- Disposable PostgreSQL 17 fixture for Shopify OAuth owner-claim concurrency.
create schema henvalt;
create schema vault;
create role anon;
create role authenticated;
create role service_role;

create type henvalt.tenant_status as enum ('ACTIVE','SUSPENDED','DISABLED');
create type henvalt.member_role as enum ('OWNER','ADMIN','MEMBER');

create table henvalt.tenants (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  status henvalt.tenant_status not null default 'ACTIVE',
  settings jsonb not null default '{}'
);
create table henvalt.shopify_connections (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references henvalt.tenants(id),
  shop_domain text not null,
  shopify_shop_id text,
  access_token_secret_ref text,
  refresh_token_secret_ref text,
  access_token_expires_at timestamptz,
  refresh_token_expires_at timestamptz,
  token_type text,
  token_updated_at timestamptz,
  scopes text[] not null default '{}',
  active boolean not null default true,
  updated_at timestamptz not null default now()
);
create unique index shopify_connections_shop_domain_uq on henvalt.shopify_connections(lower(shop_domain));
create table henvalt.tenant_memberships (
  tenant_id uuid not null references henvalt.tenants(id),
  user_id uuid not null,
  role henvalt.member_role not null,
  primary key (tenant_id,user_id)
);
create table henvalt.shopify_oauth_states (
  state_hash text primary key,
  shop_domain text not null,
  expires_at timestamptz not null,
  consumed_at timestamptz,
  initiated_by_user_id uuid not null
);
create table henvalt.audit_log (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references henvalt.tenants(id),
  event_name text not null,
  entity_type text not null,
  entity_id uuid,
  actor_type text not null,
  actor_reference text,
  payload jsonb not null default '{}'
);

create table vault.secrets (
  id uuid primary key default gen_random_uuid(),
  name text unique not null,
  secret text not null,
  description text
);
create function vault.create_secret(p_secret text,p_name text,p_description text,p_key_id uuid)
returns uuid language plpgsql security definer set search_path=pg_catalog,vault as $$
declare v_id uuid;
begin
  insert into vault.secrets(name,secret,description)
  values(p_name,p_secret,p_description)
  on conflict(name) do update set secret=excluded.secret,description=excluded.description
  returning id into v_id;
  return v_id;
end $$;
create function vault.update_secret(p_id uuid,p_secret text,p_name text,p_description text,p_key_id uuid)
returns void language sql security definer set search_path=pg_catalog,vault as $$
  update vault.secrets set secret=p_secret,name=p_name,description=p_description where id=p_id
$$;

-- Production-equivalent shop-level advisory lock and connection creation behavior.
create function henvalt.control_plane_connect_shop(p_shop_domain text)
returns jsonb language plpgsql security definer set search_path=henvalt,pg_temp as $$
declare
  v_shop text := lower(btrim(coalesce(p_shop_domain,'')));
  v_tenant_id uuid;
  v_connection_id uuid;
  v_status henvalt.tenant_status;
  v_was_active boolean := false;
  v_created boolean := false;
begin
  if v_shop !~ '^[a-z0-9][a-z0-9-]*[.]myshopify[.]com$' then
    raise exception 'Invalid Shopify shop domain' using errcode='22023';
  end if;
  perform pg_advisory_xact_lock(hashtextextended(v_shop,0));
  select sc.tenant_id,sc.id,sc.active,t.status
    into v_tenant_id,v_connection_id,v_was_active,v_status
    from henvalt.shopify_connections sc
    join henvalt.tenants t on t.id=sc.tenant_id
   where lower(sc.shop_domain)=v_shop
   limit 1 for update of sc,t;
  if v_connection_id is null then
    insert into henvalt.tenants(name,status,settings)
    values(v_shop,'ACTIVE',jsonb_build_object('provisioned_by','shopify_control_plane'))
    returning id into v_tenant_id;
    insert into henvalt.shopify_connections(tenant_id,shop_domain,scopes,active)
    values(v_tenant_id,v_shop,array['read_orders']::text[],true)
    returning id into v_connection_id;
    v_created:=true;
  else
    if v_status in ('SUSPENDED','DISABLED') then
      raise exception 'HENVALT tenant is not active' using errcode='42501';
    end if;
    update henvalt.shopify_connections set active=true,updated_at=now() where id=v_connection_id;
  end if;
  if v_created or not v_was_active then
    insert into henvalt.audit_log(tenant_id,event_name,entity_type,entity_id,actor_type,actor_reference,payload)
    values(v_tenant_id,'shopify_app_connected','shopify_connection',v_connection_id,
      'control_plane',v_shop,jsonb_build_object('shop_domain',v_shop));
  end if;
  return jsonb_build_object('linked',true,'shop_domain',v_shop,'tenant_id',v_tenant_id,'connection_id',v_connection_id);
end $$;

\i supabase/migrations/20261126170000_serialize_shopify_oauth_owner_claim.sql

insert into henvalt.shopify_oauth_states(state_hash,shop_domain,expires_at,initiated_by_user_id)
values
 ('state-user-a','race-shop.myshopify.com',now()+interval '10 minutes','aaaaaaaa-0000-4000-8000-000000000001'),
 ('state-user-b','race-shop.myshopify.com',now()+interval '10 minutes','bbbbbbbb-0000-4000-8000-000000000002'),
 ('state-user-c','race-shop.myshopify.com',now()+interval '10 minutes','cccccccc-0000-4000-8000-000000000003');

\set ON_ERROR_STOP on

-- Disposable PostgreSQL contract test for the lease-fencing migration.
-- All Supabase-specific dependencies are represented by minimal local stubs.
do $roles$
begin
  create role anon nologin;
exception when duplicate_object then null;
end
$roles$;
do $roles$
begin
  create role authenticated nologin;
exception when duplicate_object then null;
end
$roles$;
do $roles$
begin
  create role service_role nologin;
exception when duplicate_object then null;
end
$roles$;

create schema if not exists auth;
create schema if not exists vault;
create schema if not exists henvalt;

create or replace function auth.jwt() returns jsonb
language sql stable
as $$ select jsonb_build_object('role','service_role') $$;

create table henvalt.shopify_connections (
  id uuid primary key,
  tenant_id uuid not null,
  shop_domain text not null,
  active boolean not null default true,
  token_type text,
  access_token_secret_ref text,
  refresh_token_secret_ref text,
  access_token_expires_at timestamptz,
  refresh_token_expires_at timestamptz,
  token_updated_at timestamptz,
  reauth_required_at timestamptz,
  updated_at timestamptz
);

create table henvalt.audit_log (
  tenant_id uuid,
  event_name text,
  entity_type text,
  entity_id uuid,
  actor_type text,
  actor_reference text,
  payload jsonb
);

create table vault.decrypted_secrets (
  id uuid primary key,
  decrypted_secret text not null
);

create or replace function vault.update_secret(
  p_id uuid, p_secret text, p_name text, p_description text
) returns void
language plpgsql
as $$
begin
  if p_secret like 'fail-secret-write%' then raise exception 'simulated_vault_write_failure'; end if;
  update vault.decrypted_secrets set decrypted_secret=p_secret where id=p_id;
  if not found then raise exception 'vault_secret_not_found'; end if;
end;
$$;

\ir ../migrations/20261123000001_fence_shopify_token_refresh_leases.sql

insert into vault.decrypted_secrets(id,decrypted_secret) values
  ('11111111-1111-4111-8111-111111111111','old-access-token-01234567890123456789'),
  ('22222222-2222-4222-8222-222222222222','old-refresh-token-01234567890123456789');

insert into henvalt.shopify_connections(
  id,tenant_id,shop_domain,active,token_type,access_token_secret_ref,refresh_token_secret_ref,
  access_token_expires_at,refresh_token_expires_at,updated_at
) values (
  '33333333-3333-4333-8333-333333333333',
  '44444444-4444-4444-8444-444444444444',
  'demo.myshopify.com',true,'offline_expiring',
  '11111111-1111-4111-8111-111111111111',
  '22222222-2222-4222-8222-222222222222',
  now()-interval '1 minute',now()+interval '80 days',now()
);

do $test$
declare
  v_claim jsonb;
  v_result jsonb;
  v_old_lease uuid;
  v_new_lease uuid;
  v_expired_lease uuid;
  v_secret text;
  v_original_access_expiry timestamptz;
begin
  -- Valid domains must pass the corrected regex and receive a lease.
  v_claim := henvalt.claim_shopify_token_refresh('demo.myshopify.com',true);
  if v_claim->>'claimed' <> 'true' then raise exception 'valid shop was not claimed: %',v_claim; end if;
  v_old_lease := (v_claim->>'lease_id')::uuid;
  if v_old_lease is null then raise exception 'claim omitted lease ID'; end if;
  select access_token_expires_at into v_original_access_expiry
    from henvalt.shopify_connections where shop_domain='demo.myshopify.com';

  -- A second worker cannot claim while the first lease is live.
  v_result := henvalt.claim_shopify_token_refresh('demo.myshopify.com',true);
  if v_result->>'reason' <> 'REFRESH_ALREADY_IN_PROGRESS' then
    raise exception 'live lease was not exclusive: %',v_result;
  end if;

  -- Simulate expiry and a new worker taking ownership.
  v_new_lease := gen_random_uuid();
  update henvalt.shopify_connections set
    token_refresh_lease_id=v_new_lease,
    token_refresh_lease_until=now()+interval '10 minutes'
    where shop_domain='demo.myshopify.com';

  -- Old worker completion must not rotate either secret or expiry.
  v_result := henvalt.complete_shopify_token_refresh(
    'demo.myshopify.com',
    'stale-access-token-01234567890123456789',
    'stale-refresh-token-01234567890123456789',
    3600,7776000,v_old_lease
  );
  if v_result->>'reason' <> 'STALE_REFRESH_LEASE' then
    raise exception 'stale completion was accepted: %',v_result;
  end if;
  select decrypted_secret into v_secret from vault.decrypted_secrets
    where id='11111111-1111-4111-8111-111111111111';
  if v_secret <> 'old-access-token-01234567890123456789' then
    raise exception 'stale completion changed access secret';
  end if;
  select decrypted_secret into v_secret from vault.decrypted_secrets
    where id='22222222-2222-4222-8222-222222222222';
  if v_secret <> 'old-refresh-token-01234567890123456789' then
    raise exception 'stale completion changed refresh secret';
  end if;
  if (select token_refresh_lease_id from henvalt.shopify_connections where shop_domain='demo.myshopify.com') <> v_new_lease then
    raise exception 'stale completion changed replacement lease';
  end if;
  if (select access_token_expires_at from henvalt.shopify_connections where shop_domain='demo.myshopify.com') <> v_original_access_expiry then
    raise exception 'stale completion changed token expiry';
  end if;

  -- Old worker failure must not clear the replacement lease or set reauth.
  v_result := henvalt.fail_shopify_token_refresh('demo.myshopify.com','stale_failure',true,v_old_lease);
  if v_result->>'recorded' <> 'false' then raise exception 'stale failure was recorded: %',v_result; end if;
  if (select token_refresh_lease_id from henvalt.shopify_connections where shop_domain='demo.myshopify.com') <> v_new_lease then
    raise exception 'stale failure cleared replacement lease';
  end if;
  if (select reauth_required_at from henvalt.shopify_connections where shop_domain='demo.myshopify.com') is not null then
    raise exception 'stale failure set reauthorization';
  end if;

  -- A failure while writing the second secret must roll back the first secret update too.
  begin
    perform henvalt.complete_shopify_token_refresh(
      'demo.myshopify.com',
      'partial-access-token-01234567890123456789',
      'fail-secret-write-refresh-token-0123456789',
      3600,7776000,v_new_lease
    );
    raise exception 'expected simulated Vault write failure';
  exception when others then
    if sqlerrm = 'expected simulated Vault write failure' then raise; end if;
    if sqlerrm <> 'simulated_vault_write_failure' then raise; end if;
  end;
  select decrypted_secret into v_secret from vault.decrypted_secrets
    where id='11111111-1111-4111-8111-111111111111';
  if v_secret <> 'old-access-token-01234567890123456789' then
    raise exception 'partial Vault write was not rolled back';
  end if;
  if (select token_refresh_lease_id from henvalt.shopify_connections where shop_domain='demo.myshopify.com') <> v_new_lease then
    raise exception 'failed pair persistence cleared the active lease';
  end if;

  -- Current owner can atomically complete and clear its lease.
  v_result := henvalt.complete_shopify_token_refresh(
    'demo.myshopify.com',
    'new-access-token-01234567890123456789',
    'new-refresh-token-01234567890123456789',
    3600,7776000,v_new_lease
  );
  if v_result->>'refreshed' <> 'true' then raise exception 'current lease failed to complete: %',v_result; end if;
  if (select token_refresh_lease_id from henvalt.shopify_connections where shop_domain='demo.myshopify.com') is not null then
    raise exception 'successful completion did not clear lease ID';
  end if;
  select decrypted_secret into v_secret from vault.decrypted_secrets
    where id='11111111-1111-4111-8111-111111111111';
  if v_secret <> 'new-access-token-01234567890123456789' then
    raise exception 'current completion did not update access secret';
  end if;
  select decrypted_secret into v_secret from vault.decrypted_secrets
    where id='22222222-2222-4222-8222-222222222222';
  if v_secret <> 'new-refresh-token-01234567890123456789' then
    raise exception 'current completion did not update refresh secret';
  end if;

  -- Expired lease failure is also a no-op; a later claim can replace it.
  v_expired_lease := gen_random_uuid();
  update henvalt.shopify_connections set
    token_refresh_lease_id=v_expired_lease,
    token_refresh_lease_until=now()-interval '1 second'
    where shop_domain='demo.myshopify.com';
  v_result := henvalt.fail_shopify_token_refresh('demo.myshopify.com','late_failure',true,v_expired_lease);
  if v_result->>'recorded' <> 'false' then raise exception 'expired lease failure was recorded'; end if;
  v_claim := henvalt.claim_shopify_token_refresh('demo.myshopify.com',true);
  if v_claim->>'claimed' <> 'true' then raise exception 'expired lease could not be reclaimed: %',v_claim; end if;
  v_new_lease := (v_claim->>'lease_id')::uuid;

  -- A failure from the current owner may clear only its own lease.
  v_result := henvalt.fail_shopify_token_refresh('demo.myshopify.com','invalid_request',true,v_new_lease);
  if v_result->>'recorded' <> 'true' then raise exception 'current lease failure was not recorded'; end if;
  if (select token_refresh_lease_id from henvalt.shopify_connections where shop_domain='demo.myshopify.com') is not null then
    raise exception 'current failure did not clear its lease';
  end if;
  if (select reauth_required_at from henvalt.shopify_connections where shop_domain='demo.myshopify.com') is null then
    raise exception 'current terminal failure did not set reauth';
  end if;

  if has_function_privilege('anon','henvalt.claim_shopify_token_refresh(text,boolean)','EXECUTE') then
    raise exception 'anon unexpectedly has claim RPC access';
  end if;
  if has_function_privilege('authenticated','henvalt.complete_shopify_token_refresh(text,text,text,integer,integer,uuid)','EXECUTE') then
    raise exception 'authenticated unexpectedly has completion RPC access';
  end if;
  if has_function_privilege('service_role','henvalt.claim_shopify_token_refresh(text,boolean)','EXECUTE') is false
     or has_function_privilege('service_role','henvalt.complete_shopify_token_refresh(text,text,text,integer,integer,uuid)','EXECUTE') is false
     or has_function_privilege('service_role','henvalt.fail_shopify_token_refresh(text,text,boolean,uuid)','EXECUTE') is false then
    raise exception 'service_role is missing required RPC execution access';
  end if;

  raise notice 'All Shopify token refresh lease-fencing database tests passed.';
end;
$test$;

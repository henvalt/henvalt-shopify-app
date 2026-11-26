-- Disposable PostgreSQL 17 acceptance for the Shopify connection identity guard.
-- The workflow creates an empty database; this fixture models only the columns
-- and roles required by this additive migration, never staging or production.
create schema henvalt;
create role anon;
create role authenticated;
create role service_role;

create table henvalt.shopify_connections (
  id uuid primary key,
  tenant_id uuid not null,
  active boolean not null
);

create table henvalt.webhook_events (id uuid primary key, tenant_id uuid, shopify_connection_id uuid, source text, parent_ref uuid);
create table henvalt.canonical_events (id uuid primary key, tenant_id uuid, shopify_connection_id uuid, source text, parent_ref uuid);
create table henvalt.customers (id uuid primary key, tenant_id uuid, shopify_connection_id uuid, parent_ref uuid);
create table henvalt.checkouts (id uuid primary key, tenant_id uuid, shopify_connection_id uuid, parent_ref uuid);
create table henvalt.orders (id uuid primary key, tenant_id uuid, shopify_connection_id uuid, parent_ref uuid);
create table henvalt.sessions (id uuid primary key, tenant_id uuid, shopify_connection_id uuid, parent_ref uuid);
create table henvalt.opportunities (id uuid primary key, tenant_id uuid, shopify_connection_id uuid, parent_ref uuid);
create table henvalt.recovery_sequences (id uuid primary key, tenant_id uuid, shopify_connection_id uuid, parent_ref uuid);
create table henvalt.recovery_interventions (id uuid primary key, tenant_id uuid, shopify_connection_id uuid, parent_ref uuid);
create table henvalt.delivery_requests (id uuid primary key, tenant_id uuid, shopify_connection_id uuid, parent_ref uuid);
create table henvalt.delivery_attempts (id uuid primary key, tenant_id uuid, shopify_connection_id uuid, parent_ref uuid);

insert into henvalt.shopify_connections(id,tenant_id,active) values
 ('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa','11111111-1111-4111-8111-111111111111',true),
 ('bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb','22222222-2222-4222-8222-222222222222',true),
 ('cccccccc-cccc-4ccc-8ccc-cccccccccccc','11111111-1111-4111-8111-111111111111',false);

\echo 'Applying candidate migration to disposable PostgreSQL'
\i supabase/migrations/20261126150000_guard_shopify_connection_identity_immutable.sql

-- Trigger-derived mutation must be caught: alphabetic trigger order puts
-- trg_propagate before trg_shopify_connection_identity_immutable.
create function henvalt.test_parent_rewrite_connection()
returns trigger language plpgsql as $$
begin
  if new.parent_ref is not null then
    new.shopify_connection_id := new.parent_ref;
  end if;
  return new;
end $$;
create trigger trg_propagate_test_parent before update of parent_ref
on henvalt.customers for each row execute function henvalt.test_parent_rewrite_connection();

insert into henvalt.customers(id,tenant_id,shopify_connection_id)
values ('dddddddd-dddd-4ddd-8ddd-dddddddddddd','11111111-1111-4111-8111-111111111111','aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa');

do $$
begin
  begin
    update henvalt.customers set parent_ref='bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'
     where id='dddddddd-dddd-4ddd-8ddd-dddddddddddd';
    raise exception 'FAIL: trigger-derived connection rewrite was accepted';
  exception when check_violation then
    if sqlerrm not like '%SHOPIFY_CONNECTION_IDENTITY_IMMUTABLE%' then raise; end if;
  end;

  begin
    update henvalt.customers set shopify_connection_id=null
     where id='dddddddd-dddd-4ddd-8ddd-dddddddddddd';
    raise exception 'FAIL: established connection was cleared';
  exception when check_violation then
    if sqlerrm not like '%SHOPIFY_CONNECTION_IDENTITY_IMMUTABLE%' then raise; end if;
  end;

  begin
    update henvalt.customers set tenant_id='22222222-2222-4222-8222-222222222222'
     where id='dddddddd-dddd-4ddd-8ddd-dddddddddddd';
    raise exception 'FAIL: established tenant was changed';
  exception when check_violation then
    if sqlerrm not like '%SHOPIFY_CONNECTION_IDENTITY_IMMUTABLE%' then raise; end if;
  end;
end $$;

insert into henvalt.webhook_events(id,tenant_id,shopify_connection_id,source)
values ('eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee','11111111-1111-4111-8111-111111111111','aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa','shopify');
do $$
begin
  begin
    update henvalt.webhook_events set source='other'
     where id='eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee';
    raise exception 'FAIL: event source rewrite was accepted';
  exception when check_violation then
    if sqlerrm not like '%SHOPIFY_EVENT_SOURCE_IDENTITY_IMMUTABLE%' then raise; end if;
  end;
end $$;

-- Initial assignment must be active and tenant-matched.
insert into henvalt.orders(id,tenant_id) values
 ('ffffffff-ffff-4fff-8fff-ffffffffffff','11111111-1111-4111-8111-111111111111');
update henvalt.orders set shopify_connection_id='aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'
 where id='ffffffff-ffff-4fff-8fff-ffffffffffff';

insert into henvalt.orders(id,tenant_id) values
 ('99999999-9999-4999-8999-999999999999','11111111-1111-4111-8111-111111111111');
do $$
begin
  begin
    update henvalt.orders set shopify_connection_id='bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'
     where id='99999999-9999-4999-8999-999999999999';
    raise exception 'FAIL: cross-tenant initial assignment was accepted';
  exception when check_violation then
    if sqlerrm not like '%SHOPIFY_CONNECTION_IDENTITY_TENANT_MISMATCH%' then raise; end if;
  end;
end $$;

insert into henvalt.orders(id,tenant_id) values
 ('77777777-7777-4777-8777-777777777777','11111111-1111-4111-8111-111111111111');
do $
begin
  begin
    update henvalt.orders set shopify_connection_id='cccccccc-cccc-4ccc-8ccc-cccccccccccc'
     where id='77777777-7777-4777-8777-777777777777';
    raise exception 'FAIL: inactive connection assignment was accepted';
  exception when check_violation then
    if sqlerrm not like '%SHOPIFY_CONNECTION_IDENTITY_TENANT_MISMATCH%' then raise; end if;
  end;
end $;

insert into henvalt.orders(id,tenant_id,shopify_connection_id)
values ('88888888-8888-4888-8888-888888888888','11111111-1111-4111-8111-111111111111','aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa');
update henvalt.shopify_connections set active=false where id='aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
-- Deactivation must not freeze unrelated updates to already-scoped records.
update henvalt.orders set id='88888888-8888-4888-8888-888888888888'
 where id='88888888-8888-4888-8888-888888888888';

do $$
begin
  if (select count(*) from pg_trigger where tgname='trg_shopify_connection_identity_immutable' and not tgisinternal) <> 11 then
    raise exception 'FAIL: expected 11 identity triggers';
  end if;
  if has_function_privilege('anon','henvalt.guard_shopify_connection_identity_immutable()','EXECUTE')
     or has_function_privilege('authenticated','henvalt.guard_shopify_connection_identity_immutable()','EXECUTE') then
    raise exception 'FAIL: client role can execute identity guard';
  end if;
  if not has_function_privilege('service_role','henvalt.guard_shopify_connection_identity_immutable()','EXECUTE') then
    raise exception 'FAIL: service_role cannot execute identity guard';
  end if;
end $$;

\echo 'PASS: connection identity immutability, trigger-derived rewrite, source lock, tenant checks, deactivation behavior and grants'

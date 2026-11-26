-- Disposable PostgreSQL 17 acceptance for the Shopify connection identity guard.
-- Exercises the real candidate lineage migrations before the identity guard.
create schema henvalt;
create role anon;
create role authenticated;
create role service_role;

create table henvalt.shopify_connections (
  id uuid primary key,
  tenant_id uuid not null,
  active boolean not null
);
create table henvalt.webhook_events (
  id uuid primary key, tenant_id uuid not null, source text not null,
  shopify_connection_id uuid, metadata jsonb not null default '{}',
  received_at timestamptz not null default now()
);
create table henvalt.canonical_events (
  id uuid primary key, tenant_id uuid not null, source text not null,
  shopify_connection_id uuid, webhook_event_id uuid, metadata jsonb not null default '{}'
);
create table henvalt.customers (
  id uuid primary key, tenant_id uuid not null, shopify_connection_id uuid,
  metadata jsonb not null default '{}', note text
);
create table henvalt.checkouts (
  id uuid primary key, tenant_id uuid not null, shopify_connection_id uuid,
  metadata jsonb not null default '{}', customer_id uuid
);
create table henvalt.orders (
  id uuid primary key, tenant_id uuid not null, shopify_connection_id uuid,
  metadata jsonb not null default '{}', source_event_id uuid, customer_id uuid, checkout_id uuid
);
create table henvalt.sessions (
  id uuid primary key, tenant_id uuid not null, shopify_connection_id uuid,
  metadata jsonb not null default '{}', customer_id uuid
);
create table henvalt.opportunities (
  id uuid primary key, tenant_id uuid not null, shopify_connection_id uuid,
  metadata jsonb not null default '{}', source_event_id uuid, customer_id uuid, checkout_id uuid
);
create table henvalt.recovery_sequences (
  id uuid primary key, tenant_id uuid not null, shopify_connection_id uuid, opportunity_id uuid
);
create table henvalt.recovery_interventions (
  id uuid primary key, tenant_id uuid not null, shopify_connection_id uuid,
  opportunity_id uuid, sequence_id uuid
);
create table henvalt.delivery_requests (
  id uuid primary key, tenant_id uuid not null, shopify_connection_id uuid,
  intervention_id uuid, opportunity_id uuid
);
create table henvalt.delivery_attempts (
  id uuid primary key, tenant_id uuid not null, shopify_connection_id uuid, delivery_request_id uuid
);

insert into henvalt.shopify_connections(id,tenant_id,active) values
 ('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa','11111111-1111-4111-8111-111111111111',true),
 ('bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb','11111111-1111-4111-8111-111111111111',true),
 ('cccccccc-cccc-4ccc-8ccc-cccccccccccc','22222222-2222-4222-8222-222222222222',true),
 ('dddddddd-dddd-4ddd-8ddd-dddddddddddd','11111111-1111-4111-8111-111111111111',false);

\echo 'Apply actual candidate connection lineage migrations'
\i supabase/migrations/202611260007_propagate_shopify_connection_to_recovery_graph.sql
\i supabase/migrations/202611260009_enforce_shopify_connection_parent_lineage.sql
\i supabase/migrations/20261126150000_guard_shopify_connection_identity_immutable.sql

-- Parent propagation trigger runs before the identity guard by PostgreSQL's
-- alphabetical trigger ordering. Both connections belong to the same tenant,
-- so lineage validation permits the attempted store switch; the identity guard
-- must reject it.
insert into henvalt.customers(id,tenant_id,metadata)
values ('eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee',
 '11111111-1111-4111-8111-111111111111',
 '{"shopify_connection_id":"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"}');
do $$
begin
  begin
    update henvalt.customers
       set metadata=jsonb_set(metadata,'{shopify_connection_id}',
         '"bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"')
     where id='eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee';
    raise exception 'FAIL: trigger-derived same-tenant store switch was accepted';
  exception when check_violation then
    if sqlerrm not like '%SHOPIFY_CONNECTION_IDENTITY_IMMUTABLE%' then raise; end if;
  end;
end $$;

-- The real propagation trigger restores a column-only clear from the
-- authoritative metadata before the immutable guard runs. Verify identity
-- remains unchanged; test direct clearing separately on the ingress row below.
update henvalt.customers set shopify_connection_id=null
 where id='eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee';
do $
begin
  if (select shopify_connection_id from henvalt.customers
       where id='eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee')
     is distinct from 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'::uuid then
    raise exception 'FAIL: propagation did not preserve established connection identity';
  end if;
  begin
    update henvalt.customers set tenant_id='22222222-2222-4222-8222-222222222222'
     where id='eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee';
    raise exception 'FAIL: established tenant was changed';
  exception when check_violation then
    if sqlerrm not like '%SHOPIFY_CONNECTION_IDENTITY_IMMUTABLE%' then raise; end if;
  end;
end $;

-- Webhook/canonical source identity is immutable after insert.
insert into henvalt.webhook_events(id,tenant_id,source)
values ('ffffffff-ffff-4fff-8fff-ffffffffffff','11111111-1111-4111-8111-111111111111','shopify');
do $$
begin
  begin
    update henvalt.webhook_events set source='other'
     where id='ffffffff-ffff-4fff-8fff-ffffffffffff';
    raise exception 'FAIL: webhook source rewrite was accepted';
  exception when check_violation then
    if sqlerrm not like '%SHOPIFY_EVENT_SOURCE_IDENTITY_IMMUTABLE%' then raise; end if;
  end;
end $$;
insert into henvalt.canonical_events(id,tenant_id,source)
values ('99999999-9999-4999-8999-999999999999','11111111-1111-4111-8111-111111111111','shopify');
do $$
begin
  begin
    update henvalt.canonical_events set source='other'
     where id='99999999-9999-4999-8999-999999999999';
    raise exception 'FAIL: canonical event source rewrite was accepted';
  exception when check_violation then
    if sqlerrm not like '%SHOPIFY_EVENT_SOURCE_IDENTITY_IMMUTABLE%' then raise; end if;
  end;
end $$;

-- First-time assignment is allowed only for an active same-tenant connection.
insert into henvalt.webhook_events(id,tenant_id,source)
values ('88888888-8888-4888-8888-888888888888','11111111-1111-4111-8111-111111111111','fixture');
update henvalt.webhook_events set shopify_connection_id='aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'
 where id='88888888-8888-4888-8888-888888888888';
do $
begin
  begin
    update henvalt.webhook_events set shopify_connection_id=null
     where id='88888888-8888-4888-8888-888888888888';
    raise exception 'FAIL: established ingress connection was cleared';
  exception when check_violation then
    if sqlerrm not like '%SHOPIFY_CONNECTION_IDENTITY_IMMUTABLE%' then raise; end if;
  end;
end $;

insert into henvalt.webhook_events(id,tenant_id,source)
values ('77777777-7777-4777-8777-777777777777','11111111-1111-4111-8111-111111111111','fixture');
do $$
begin
  begin
    update henvalt.webhook_events set shopify_connection_id='cccccccc-cccc-4ccc-8ccc-cccccccccccc'
     where id='77777777-7777-4777-8777-777777777777';
    raise exception 'FAIL: cross-tenant initial assignment was accepted';
  exception when check_violation then
    if sqlerrm not like '%SHOPIFY_CONNECTION_IDENTITY_TENANT_MISMATCH%' then raise; end if;
  end;
end $$;

insert into henvalt.webhook_events(id,tenant_id,source)
values ('66666666-6666-4666-8666-666666666666','11111111-1111-4111-8111-111111111111','fixture');
do $$
begin
  begin
    update henvalt.webhook_events set shopify_connection_id='dddddddd-dddd-4ddd-8ddd-dddddddddddd'
     where id='66666666-6666-4666-8666-666666666666';
    raise exception 'FAIL: inactive initial assignment was accepted';
  exception when check_violation then
    if sqlerrm not like '%SHOPIFY_CONNECTION_IDENTITY_TENANT_MISMATCH%' then raise; end if;
  end;
end $$;

-- Deactivation must not make unrelated fields immutable.
update henvalt.shopify_connections set active=false where id='aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
update henvalt.customers set note='unrelated safe update'
 where id='eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee';

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

\echo 'PASS: real lineage triggers, identity immutability, source lock, tenant checks, deactivation behavior and grants'

-- Establish authoritative Shopify connection identity at webhook ingress.
-- Existing records remain nullable: do not guess/backfill ownership where it
-- was not captured. New/replayed Shopify webhooks must resolve exactly one
-- active connection for the signed shop domain and tenant.
alter table henvalt.webhook_events
  add column if not exists shopify_connection_id uuid;

alter table henvalt.canonical_events
  add column if not exists shopify_connection_id uuid;

do $constraints$
begin
  if not exists (
    select 1 from pg_constraint
    where conname = 'webhook_events_shopify_connection_id_fkey'
      and conrelid = 'henvalt.webhook_events'::regclass
  ) then
    alter table henvalt.webhook_events
      add constraint webhook_events_shopify_connection_id_fkey
      foreign key (shopify_connection_id)
      references henvalt.shopify_connections(id)
      on delete restrict;
  end if;

  if not exists (
    select 1 from pg_constraint
    where conname = 'canonical_events_shopify_connection_id_fkey'
      and conrelid = 'henvalt.canonical_events'::regclass
  ) then
    alter table henvalt.canonical_events
      add constraint canonical_events_shopify_connection_id_fkey
      foreign key (shopify_connection_id)
      references henvalt.shopify_connections(id)
      on delete restrict;
  end if;
end
$constraints$;

create index if not exists webhook_events_connection_received_idx
  on henvalt.webhook_events(shopify_connection_id, received_at desc)
  where shopify_connection_id is not null;

create index if not exists canonical_events_connection_received_idx
  on henvalt.canonical_events(shopify_connection_id, received_at desc)
  where shopify_connection_id is not null;

create or replace function henvalt.capture_shopify_webhook_connection_scope()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, henvalt, pg_temp
as $function$
declare
  v_domain text;
  v_match_count integer;
  v_connection_id uuid;
  v_match_tenant_id uuid;
begin
  if new.source is distinct from 'shopify' then
    return new;
  end if;

  -- Explicit scope is accepted only when it matches this tenant and shop.
  if new.shopify_connection_id is not null then
    select count(*), (array_agg(sc.id))[1], (array_agg(sc.tenant_id))[1]
      into v_match_count, v_connection_id, v_match_tenant_id
      from henvalt.shopify_connections sc
      join henvalt.tenants t on t.id = sc.tenant_id
     where lower(sc.shop_domain) = lower(coalesce(new.metadata->>'shop_domain', ''))
       and sc.active = true
       and t.status = 'ACTIVE';
    if v_match_count <> 1
       or v_connection_id is distinct from new.shopify_connection_id
       or v_match_tenant_id is distinct from new.tenant_id then
      raise exception 'SHOPIFY_WEBHOOK_CONNECTION_SCOPE_MISMATCH'
        using errcode = '23514';
    end if;
    return new;
  end if;

  -- Only resolve on first insert or when a replay refreshes its receipt time.
  -- Ordinary status updates to historical unscoped rows remain possible.
  if tg_op = 'UPDATE'
     and old.shopify_connection_id is null
     and new.received_at is not distinct from old.received_at
     and new.metadata->>'shop_domain' is not distinct from old.metadata->>'shop_domain'
  then
    return new;
  end if;

  v_domain := lower(btrim(coalesce(new.metadata->>'shop_domain', '')));
  if v_domain !~ '^[a-z0-9][a-z0-9-]*[.]myshopify[.]com$' then
    raise exception 'SHOPIFY_WEBHOOK_SHOP_DOMAIN_MISSING_OR_INVALID'
      using errcode = '22023';
  end if;

  select count(*), (array_agg(sc.id))[1], (array_agg(sc.tenant_id))[1]
    into v_match_count, v_connection_id, v_match_tenant_id
    from henvalt.shopify_connections sc
    join henvalt.tenants t on t.id = sc.tenant_id
   where lower(sc.shop_domain) = v_domain
     and sc.active = true
     and t.status = 'ACTIVE';

  if v_match_count <> 1 or v_match_tenant_id is distinct from new.tenant_id then
    raise exception 'SHOPIFY_WEBHOOK_CONNECTION_NOT_UNIQUE_OR_INACTIVE'
      using errcode = '23514';
  end if;

  new.shopify_connection_id := v_connection_id;
  return new;
end;
$function$;

drop trigger if exists trg_capture_shopify_webhook_connection_scope
  on henvalt.webhook_events;
create trigger trg_capture_shopify_webhook_connection_scope
before insert or update of shopify_connection_id, metadata, received_at
on henvalt.webhook_events
for each row execute function henvalt.capture_shopify_webhook_connection_scope();

create or replace function henvalt.capture_canonical_event_connection_scope()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, henvalt, pg_temp
as $function$
declare
  v_connection_id uuid;
  v_tenant_id uuid;
begin
  if new.source is distinct from 'shopify' then
    return new;
  end if;

  if tg_op = 'UPDATE'
     and new.webhook_event_id is not distinct from old.webhook_event_id
     and new.shopify_connection_id is not distinct from old.shopify_connection_id
  then
    return new;
  end if;

  if new.webhook_event_id is null then
    raise exception 'SHOPIFY_CANONICAL_EVENT_WEBHOOK_REFERENCE_REQUIRED'
      using errcode = '23514';
  end if;

  select w.shopify_connection_id, w.tenant_id
    into v_connection_id, v_tenant_id
    from henvalt.webhook_events w
   where w.id = new.webhook_event_id
     and w.source = 'shopify';

  if not found
     or v_connection_id is null
     or v_tenant_id is distinct from new.tenant_id
  then
    raise exception 'SHOPIFY_CANONICAL_EVENT_CONNECTION_SCOPE_MISSING'
      using errcode = '23514';
  end if;

  if new.shopify_connection_id is not null
     and new.shopify_connection_id is distinct from v_connection_id
  then
    raise exception 'SHOPIFY_CANONICAL_EVENT_CONNECTION_SCOPE_MISMATCH'
      using errcode = '23514';
  end if;

  new.shopify_connection_id := v_connection_id;
  return new;
end;
$function$;

drop trigger if exists trg_capture_canonical_event_connection_scope
  on henvalt.canonical_events;
create trigger trg_capture_canonical_event_connection_scope
before insert or update of webhook_event_id, shopify_connection_id
on henvalt.canonical_events
for each row execute function henvalt.capture_canonical_event_connection_scope();

revoke all on function henvalt.capture_shopify_webhook_connection_scope()
  from public, anon, authenticated;
revoke all on function henvalt.capture_canonical_event_connection_scope()
  from public, anon, authenticated;

-- Propagate authoritative Shopify connection identity beyond event ingress.
-- This migration does not backfill legacy rows or infer store ownership.
alter table henvalt.customers add column if not exists shopify_connection_id uuid;
alter table henvalt.checkouts add column if not exists shopify_connection_id uuid;
alter table henvalt.orders add column if not exists shopify_connection_id uuid;
alter table henvalt.sessions add column if not exists shopify_connection_id uuid;
alter table henvalt.opportunities add column if not exists shopify_connection_id uuid;
alter table henvalt.recovery_interventions add column if not exists shopify_connection_id uuid;
alter table henvalt.delivery_requests add column if not exists shopify_connection_id uuid;

do $constraints$
declare t text;
begin
  foreach t in array array['customers','checkouts','orders','sessions','opportunities','recovery_interventions','delivery_requests'] loop
    if not exists (
      select 1 from pg_constraint
      where conname=t||'_shopify_connection_id_fkey'
        and conrelid=format('henvalt.%I',t)::regclass
    ) then
      execute format(
        'alter table henvalt.%I add constraint %I foreign key (shopify_connection_id) references henvalt.shopify_connections(id) on delete restrict',
        t,t||'_shopify_connection_id_fkey'
      );
    end if;
    execute format(
      'create index if not exists %I on henvalt.%I(shopify_connection_id) where shopify_connection_id is not null',
      t||'_connection_scope_idx',t
    );
  end loop;
end
$constraints$;

create or replace function henvalt.propagate_shopify_connection_scope()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, henvalt, pg_temp
as $function$
declare
  v_row jsonb := to_jsonb(new);
  v_metadata jsonb;
  v_connection_id uuid;
  v_parent_connection_id uuid;
  v_tenant_id uuid;
  v_parent_tenant_id uuid;
  v_event_id uuid;
  v_opportunity_id uuid;
  v_intervention_id uuid;
  v_connection_text text;
begin
  v_tenant_id := (v_row->>'tenant_id')::uuid;
  v_metadata := coalesce(v_row->'metadata','{}'::jsonb);
  v_connection_text := nullif(v_metadata->>'shopify_connection_id','');

  if v_connection_text is not null then
    begin
      v_connection_id := v_connection_text::uuid;
    exception when invalid_text_representation then
      raise exception 'SHOPIFY_CONNECTION_SCOPE_INVALID_UUID' using errcode='22023';
    end;
  end if;

  if tg_table_name in ('orders','opportunities') then
    v_event_id := nullif(coalesce(v_metadata->>'last_event_id',v_metadata->>'source_event_id'),'')::uuid;
    if v_event_id is not null then
      select ce.shopify_connection_id,ce.tenant_id
        into v_parent_connection_id,v_parent_tenant_id
        from henvalt.canonical_events ce
       where ce.id=v_event_id;
      if not found or v_parent_tenant_id is distinct from v_tenant_id then
        raise exception 'SHOPIFY_CONNECTION_SCOPE_EVENT_PARENT_MISMATCH' using errcode='23514';
      end if;
    end if;
  elsif tg_table_name='recovery_interventions' then
    v_opportunity_id := nullif(v_row->>'opportunity_id','')::uuid;
    select o.shopify_connection_id,o.tenant_id
      into v_parent_connection_id,v_parent_tenant_id
      from henvalt.opportunities o where o.id=v_opportunity_id;
    if not found or v_parent_tenant_id is distinct from v_tenant_id then
      raise exception 'SHOPIFY_CONNECTION_SCOPE_OPPORTUNITY_PARENT_MISMATCH' using errcode='23514';
    end if;
  elsif tg_table_name='delivery_requests' then
    v_intervention_id := nullif(v_row->>'intervention_id','')::uuid;
    select ri.shopify_connection_id,ri.tenant_id
      into v_parent_connection_id,v_parent_tenant_id
      from henvalt.recovery_interventions ri where ri.id=v_intervention_id;
    if not found or v_parent_tenant_id is distinct from v_tenant_id then
      raise exception 'SHOPIFY_CONNECTION_SCOPE_INTERVENTION_PARENT_MISMATCH' using errcode='23514';
    end if;
  end if;

  if v_connection_id is not null and v_parent_connection_id is not null
     and v_connection_id is distinct from v_parent_connection_id then
    raise exception 'SHOPIFY_CONNECTION_SCOPE_PARENT_MISMATCH' using errcode='23514';
  end if;

  v_connection_id := coalesce(v_connection_id,v_parent_connection_id);

  if v_connection_id is not null then
    select sc.tenant_id into v_parent_tenant_id
      from henvalt.shopify_connections sc
     where sc.id=v_connection_id and sc.active=true;
    if not found or v_parent_tenant_id is distinct from v_tenant_id then
      raise exception 'SHOPIFY_CONNECTION_SCOPE_NOT_ACTIVE_FOR_TENANT' using errcode='23514';
    end if;
    v_row := jsonb_set(v_row,'{shopify_connection_id}',to_jsonb(v_connection_id::text),true);
    new := jsonb_populate_record(new,v_row);
  end if;

  return new;
end;
$function$;

do $triggers$
declare t text;
begin
  foreach t in array array['customers','checkouts','orders','sessions','opportunities','recovery_interventions','delivery_requests'] loop
    execute format('drop trigger if exists trg_propagate_shopify_connection_scope on henvalt.%I',t);
    execute format(
      'create trigger trg_propagate_shopify_connection_scope before insert or update of shopify_connection_id,metadata on henvalt.%I for each row execute function henvalt.propagate_shopify_connection_scope()',
      t
    );
  end loop;
end
$triggers$;

revoke all on function henvalt.propagate_shopify_connection_scope()
  from public, anon, authenticated;
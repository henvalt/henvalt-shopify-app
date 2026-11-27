-- Extend connection lineage to the remaining recovery and delivery descendants.
alter table henvalt.recovery_sequences add column if not exists shopify_connection_id uuid;
alter table henvalt.delivery_attempts add column if not exists shopify_connection_id uuid;

do $constraints$
begin
 if not exists(select 1 from pg_constraint where conname='recovery_sequences_shopify_connection_id_fkey' and conrelid='henvalt.recovery_sequences'::regclass) then
  alter table henvalt.recovery_sequences add constraint recovery_sequences_shopify_connection_id_fkey foreign key(shopify_connection_id) references henvalt.shopify_connections(id) on delete restrict;
 end if;
 if not exists(select 1 from pg_constraint where conname='delivery_attempts_shopify_connection_id_fkey' and conrelid='henvalt.delivery_attempts'::regclass) then
  alter table henvalt.delivery_attempts add constraint delivery_attempts_shopify_connection_id_fkey foreign key(shopify_connection_id) references henvalt.shopify_connections(id) on delete restrict;
 end if;
end
$constraints$;
create index if not exists recovery_sequences_connection_scope_idx on henvalt.recovery_sequences(shopify_connection_id) where shopify_connection_id is not null;
create index if not exists delivery_attempts_connection_scope_idx on henvalt.delivery_attempts(shopify_connection_id) where shopify_connection_id is not null;

create or replace function henvalt.propagate_shopify_connection_scope()
returns trigger language plpgsql security definer set search_path=pg_catalog,henvalt,pg_temp
as $function$
declare
 v_row jsonb:=to_jsonb(new); v_metadata jsonb; v_connection_id uuid; v_parent_connection_id uuid; v_tenant_id uuid; v_parent_tenant_id uuid; v_event_id uuid; v_opportunity_id uuid; v_intervention_id uuid; v_delivery_id uuid; v_connection_text text;
begin
 v_tenant_id:=(v_row->>'tenant_id')::uuid;
 v_metadata:=coalesce(v_row->'metadata','{}'::jsonb);
 v_connection_text:=nullif(v_metadata->>'shopify_connection_id','');
 if v_connection_text is not null then
  begin v_connection_id:=v_connection_text::uuid;
  exception when invalid_text_representation then raise exception 'SHOPIFY_CONNECTION_SCOPE_INVALID_UUID' using errcode='22023'; end;
 end if;

 if tg_table_name in ('orders','opportunities') then
  v_event_id:=nullif(coalesce(v_metadata->>'last_event_id',v_metadata->>'source_event_id'),'')::uuid;
  if v_event_id is not null then
   select ce.shopify_connection_id,ce.tenant_id into v_parent_connection_id,v_parent_tenant_id from henvalt.canonical_events ce where ce.id=v_event_id;
   if not found or v_parent_tenant_id is distinct from v_tenant_id then raise exception 'SHOPIFY_CONNECTION_SCOPE_EVENT_PARENT_MISMATCH' using errcode='23514'; end if;
  end if;
 elsif tg_table_name in ('recovery_sequences','recovery_interventions') then
  v_opportunity_id:=nullif(v_row->>'opportunity_id','')::uuid;
  select o.shopify_connection_id,o.tenant_id into v_parent_connection_id,v_parent_tenant_id from henvalt.opportunities o where o.id=v_opportunity_id;
  if not found or v_parent_tenant_id is distinct from v_tenant_id then raise exception 'SHOPIFY_CONNECTION_SCOPE_OPPORTUNITY_PARENT_MISMATCH' using errcode='23514'; end if;
 elsif tg_table_name='delivery_requests' then
  v_intervention_id:=nullif(v_row->>'intervention_id','')::uuid;
  select ri.shopify_connection_id,ri.tenant_id into v_parent_connection_id,v_parent_tenant_id from henvalt.recovery_interventions ri where ri.id=v_intervention_id;
  if not found or v_parent_tenant_id is distinct from v_tenant_id then raise exception 'SHOPIFY_CONNECTION_SCOPE_INTERVENTION_PARENT_MISMATCH' using errcode='23514'; end if;
 elsif tg_table_name='delivery_attempts' then
  v_delivery_id:=nullif(v_row->>'delivery_request_id','')::uuid;
  select dr.shopify_connection_id,dr.tenant_id into v_parent_connection_id,v_parent_tenant_id from henvalt.delivery_requests dr where dr.id=v_delivery_id;
  if not found or v_parent_tenant_id is distinct from v_tenant_id then raise exception 'SHOPIFY_CONNECTION_SCOPE_DELIVERY_PARENT_MISMATCH' using errcode='23514'; end if;
 end if;

 if v_connection_id is not null and v_parent_connection_id is not null and v_connection_id is distinct from v_parent_connection_id then
  raise exception 'SHOPIFY_CONNECTION_SCOPE_PARENT_MISMATCH' using errcode='23514';
 end if;
 v_connection_id:=coalesce(v_connection_id,v_parent_connection_id);
 if v_connection_id is not null then
  select sc.tenant_id into v_parent_tenant_id from henvalt.shopify_connections sc where sc.id=v_connection_id and sc.active=true;
  if not found or v_parent_tenant_id is distinct from v_tenant_id then raise exception 'SHOPIFY_CONNECTION_SCOPE_NOT_ACTIVE_FOR_TENANT' using errcode='23514'; end if;
  v_row:=jsonb_set(v_row,'{shopify_connection_id}',to_jsonb(v_connection_id::text),true);
  new:=jsonb_populate_record(new,v_row);
 end if;
 return new;
end;
$function$;

drop trigger if exists trg_propagate_shopify_connection_scope on henvalt.recovery_sequences;
create trigger trg_propagate_shopify_connection_scope before insert or update of shopify_connection_id on henvalt.recovery_sequences for each row execute function henvalt.propagate_shopify_connection_scope();
drop trigger if exists trg_propagate_shopify_connection_scope on henvalt.delivery_attempts;
create trigger trg_propagate_shopify_connection_scope before insert or update of shopify_connection_id on henvalt.delivery_attempts for each row execute function henvalt.propagate_shopify_connection_scope();

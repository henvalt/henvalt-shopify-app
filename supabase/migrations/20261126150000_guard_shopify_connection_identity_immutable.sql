-- Preserve Shopify connection identity after it has been established.
-- The earlier lineage triggers validate parent changes, but their UPDATE OF
-- lists do not include tenant_id (and source changes on event rows). This
-- guard makes the captured tenant/store identity immutable across the graph.
create or replace function henvalt.guard_shopify_connection_identity_immutable()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, henvalt, pg_temp
as $function$
declare
  v_old jsonb := to_jsonb(old);
  v_new jsonb := to_jsonb(new);
  v_old_connection_id uuid;
  v_new_connection_id uuid;
  v_old_tenant_id uuid;
  v_new_tenant_id uuid;
  v_connection_tenant_id uuid;
begin
  v_old_connection_id := nullif(v_old->>'shopify_connection_id','')::uuid;
  v_new_connection_id := nullif(v_new->>'shopify_connection_id','')::uuid;
  v_old_tenant_id := nullif(v_old->>'tenant_id','')::uuid;
  v_new_tenant_id := nullif(v_new->>'tenant_id','')::uuid;

  if tg_table_name in ('webhook_events','canonical_events')
     and v_old->>'source' is distinct from v_new->>'source' then
    raise exception 'SHOPIFY_EVENT_SOURCE_IDENTITY_IMMUTABLE'
      using errcode='23514';
  end if;

  if v_old_connection_id is not null and
     (v_new_connection_id is distinct from v_old_connection_id or
      v_new_tenant_id is distinct from v_old_tenant_id) then
    raise exception 'SHOPIFY_CONNECTION_IDENTITY_IMMUTABLE'
      using errcode='23514';
  end if;

  -- Validate activity only when identity is first assigned. Existing rows must
  -- remain mutable for non-identity fields even if their connection is later
  -- deactivated; changing or clearing an established identity is rejected above.
  if v_new_connection_id is not null and v_old_connection_id is null then
    select sc.tenant_id into v_connection_tenant_id
      from henvalt.shopify_connections sc
     where sc.id=v_new_connection_id and sc.active=true;
    if not found or v_connection_tenant_id is distinct from v_new_tenant_id then
      raise exception 'SHOPIFY_CONNECTION_IDENTITY_TENANT_MISMATCH'
        using errcode='23514';
    end if;
  end if;

  return new;
end;
$function$;

revoke all on function henvalt.guard_shopify_connection_identity_immutable()
  from public, anon, authenticated;
grant execute on function henvalt.guard_shopify_connection_identity_immutable()
  to service_role;

drop trigger if exists trg_shopify_connection_identity_immutable on henvalt.webhook_events;
create trigger trg_shopify_connection_identity_immutable
before update
on henvalt.webhook_events
for each row execute function henvalt.guard_shopify_connection_identity_immutable();

drop trigger if exists trg_shopify_connection_identity_immutable on henvalt.canonical_events;
create trigger trg_shopify_connection_identity_immutable
before update
on henvalt.canonical_events
for each row execute function henvalt.guard_shopify_connection_identity_immutable();

drop trigger if exists trg_shopify_connection_identity_immutable on henvalt.customers;
create trigger trg_shopify_connection_identity_immutable
before update
on henvalt.customers
for each row execute function henvalt.guard_shopify_connection_identity_immutable();

drop trigger if exists trg_shopify_connection_identity_immutable on henvalt.checkouts;
create trigger trg_shopify_connection_identity_immutable
before update
on henvalt.checkouts
for each row execute function henvalt.guard_shopify_connection_identity_immutable();

drop trigger if exists trg_shopify_connection_identity_immutable on henvalt.orders;
create trigger trg_shopify_connection_identity_immutable
before update
on henvalt.orders
for each row execute function henvalt.guard_shopify_connection_identity_immutable();

drop trigger if exists trg_shopify_connection_identity_immutable on henvalt.sessions;
create trigger trg_shopify_connection_identity_immutable
before update
on henvalt.sessions
for each row execute function henvalt.guard_shopify_connection_identity_immutable();

drop trigger if exists trg_shopify_connection_identity_immutable on henvalt.opportunities;
create trigger trg_shopify_connection_identity_immutable
before update
on henvalt.opportunities
for each row execute function henvalt.guard_shopify_connection_identity_immutable();

drop trigger if exists trg_shopify_connection_identity_immutable on henvalt.recovery_sequences;
create trigger trg_shopify_connection_identity_immutable
before update
on henvalt.recovery_sequences
for each row execute function henvalt.guard_shopify_connection_identity_immutable();

drop trigger if exists trg_shopify_connection_identity_immutable on henvalt.recovery_interventions;
create trigger trg_shopify_connection_identity_immutable
before update
on henvalt.recovery_interventions
for each row execute function henvalt.guard_shopify_connection_identity_immutable();

drop trigger if exists trg_shopify_connection_identity_immutable on henvalt.delivery_requests;
create trigger trg_shopify_connection_identity_immutable
before update
on henvalt.delivery_requests
for each row execute function henvalt.guard_shopify_connection_identity_immutable();

drop trigger if exists trg_shopify_connection_identity_immutable on henvalt.delivery_attempts;
create trigger trg_shopify_connection_identity_immutable
before update
on henvalt.delivery_attempts
for each row execute function henvalt.guard_shopify_connection_identity_immutable();

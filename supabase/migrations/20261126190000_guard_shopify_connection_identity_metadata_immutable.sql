-- Protect metadata-derived Shopify connection identity before propagation.
-- Customer, checkout and session metadata can be authoritative inputs to
-- connection propagation; comparing only the connection column is insufficient
-- when this guard intentionally runs before propagation triggers.
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
  v_old_metadata_connection_id uuid;
  v_new_metadata_connection_id uuid;
  v_old_tenant_id uuid;
  v_new_tenant_id uuid;
  v_connection_tenant_id uuid;
  v_identity_to_validate uuid;
begin
  v_old_connection_id := nullif(v_old->>'shopify_connection_id','')::uuid;
  v_new_connection_id := nullif(v_new->>'shopify_connection_id','')::uuid;
  v_old_metadata_connection_id := nullif(v_old->'metadata'->>'shopify_connection_id','')::uuid;
  v_new_metadata_connection_id := nullif(v_new->'metadata'->>'shopify_connection_id','')::uuid;
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

  if v_old_metadata_connection_id is not null and
     v_new_metadata_connection_id is distinct from v_old_metadata_connection_id then
    raise exception 'SHOPIFY_CONNECTION_IDENTITY_IMMUTABLE'
      using errcode='23514';
  end if;
  if v_old_connection_id is not null and
     v_new_metadata_connection_id is not null and
     v_new_metadata_connection_id is distinct from v_old_connection_id then
    raise exception 'SHOPIFY_CONNECTION_IDENTITY_IMMUTABLE'
      using errcode='23514';
  end if;

  v_identity_to_validate := coalesce(v_new_connection_id, v_new_metadata_connection_id);
  if v_identity_to_validate is not null and
     v_old_connection_id is null and
     v_old_metadata_connection_id is null then
    select sc.tenant_id into v_connection_tenant_id
      from henvalt.shopify_connections sc
     where sc.id=v_identity_to_validate and sc.active=true;
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

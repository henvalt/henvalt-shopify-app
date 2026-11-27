-- Enforce exact parent-object identity for the final recovery graph edges.
-- This is additive and intentionally does not backfill historical rows.

create or replace function henvalt.validate_shopify_recovery_parent_links()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, henvalt, pg_temp
as $function$
declare
  v_tenant_id uuid;
  v_connection_id uuid;
  v_sequence_opportunity_id uuid;
  v_sequence_tenant_id uuid;
  v_sequence_connection_id uuid;
  v_intervention_opportunity_id uuid;
  v_intervention_tenant_id uuid;
  v_intervention_connection_id uuid;
begin
  v_tenant_id := (to_jsonb(new)->>'tenant_id')::uuid;
  v_connection_id := nullif(to_jsonb(new)->>'shopify_connection_id','')::uuid;

  if tg_table_name = 'recovery_interventions' then
    if new.sequence_id is not null then
      select rs.opportunity_id, rs.tenant_id, rs.shopify_connection_id
        into v_sequence_opportunity_id, v_sequence_tenant_id, v_sequence_connection_id
        from henvalt.recovery_sequences rs
       where rs.id = new.sequence_id;
      if not found
         or v_sequence_tenant_id is distinct from v_tenant_id
         or v_sequence_opportunity_id is distinct from new.opportunity_id then
        raise exception 'SHOPIFY_CONNECTION_SCOPE_SEQUENCE_OPPORTUNITY_MISMATCH'
          using errcode='23514';
      end if;
      if v_connection_id is not null and v_sequence_connection_id is not null
         and v_connection_id is distinct from v_sequence_connection_id then
        raise exception 'SHOPIFY_CONNECTION_SCOPE_SEQUENCE_STORE_MISMATCH'
          using errcode='23514';
      end if;
    end if;
  elsif tg_table_name = 'delivery_requests' then
    select ri.opportunity_id, ri.tenant_id, ri.shopify_connection_id
      into v_intervention_opportunity_id, v_intervention_tenant_id, v_intervention_connection_id
      from henvalt.recovery_interventions ri
     where ri.id = new.intervention_id;
    if not found
       or v_intervention_tenant_id is distinct from v_tenant_id then
      raise exception 'SHOPIFY_CONNECTION_SCOPE_DELIVERY_INTERVENTION_MISMATCH'
        using errcode='23514';
    end if;
    if new.opportunity_id is null then
      new.opportunity_id := v_intervention_opportunity_id;
    elsif new.opportunity_id is distinct from v_intervention_opportunity_id then
      raise exception 'SHOPIFY_CONNECTION_SCOPE_DELIVERY_OPPORTUNITY_MISMATCH'
        using errcode='23514';
    end if;
    if v_connection_id is not null and v_intervention_connection_id is not null
       and v_connection_id is distinct from v_intervention_connection_id then
      raise exception 'SHOPIFY_CONNECTION_SCOPE_DELIVERY_STORE_MISMATCH'
        using errcode='23514';
    end if;
  end if;
  return new;
end;
$function$;

revoke all on function henvalt.validate_shopify_recovery_parent_links() from public, anon, authenticated;
grant execute on function henvalt.validate_shopify_recovery_parent_links() to service_role;

drop trigger if exists trg_validate_shopify_recovery_parent_links on henvalt.recovery_interventions;
create trigger trg_validate_shopify_recovery_parent_links
before insert or update of tenant_id, shopify_connection_id, opportunity_id, sequence_id
on henvalt.recovery_interventions
for each row execute function henvalt.validate_shopify_recovery_parent_links();

drop trigger if exists trg_validate_shopify_recovery_parent_links on henvalt.delivery_requests;
create trigger trg_validate_shopify_recovery_parent_links
before insert or update of tenant_id, shopify_connection_id, opportunity_id, intervention_id
on henvalt.delivery_requests
for each row execute function henvalt.validate_shopify_recovery_parent_links();

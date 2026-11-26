-- Make the authoritative connection ID available to the existing replay
-- projection contract, which already transports webhook metadata to workers.
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
  if new.source is distinct from 'shopify' then return new; end if;

  if new.shopify_connection_id is not null then
    select count(*),(array_agg(sc.id))[1],(array_agg(sc.tenant_id))[1]
      into v_match_count,v_connection_id,v_match_tenant_id
      from henvalt.shopify_connections sc
      join henvalt.tenants t on t.id=sc.tenant_id
     where lower(sc.shop_domain)=lower(coalesce(new.metadata->>'shop_domain',''))
       and sc.active=true and t.status='ACTIVE';
    if v_match_count<>1
       or v_connection_id is distinct from new.shopify_connection_id
       or v_match_tenant_id is distinct from new.tenant_id then
      raise exception 'SHOPIFY_WEBHOOK_CONNECTION_SCOPE_MISMATCH' using errcode='23514';
    end if;
    new.metadata:=coalesce(new.metadata,'{}'::jsonb)
      || jsonb_build_object('shopify_connection_id',v_connection_id);
    return new;
  end if;

  if tg_op='UPDATE'
     and old.shopify_connection_id is null
     and new.received_at is not distinct from old.received_at
     and new.metadata->>'shop_domain' is not distinct from old.metadata->>'shop_domain'
  then
    return new;
  end if;

  v_domain:=lower(btrim(coalesce(new.metadata->>'shop_domain','')));
  if v_domain !~ '^[a-z0-9][a-z0-9-]*[.]myshopify[.]com$' then
    raise exception 'SHOPIFY_WEBHOOK_SHOP_DOMAIN_MISSING_OR_INVALID' using errcode='22023';
  end if;

  select count(*),(array_agg(sc.id))[1],(array_agg(sc.tenant_id))[1]
    into v_match_count,v_connection_id,v_match_tenant_id
    from henvalt.shopify_connections sc
    join henvalt.tenants t on t.id=sc.tenant_id
   where lower(sc.shop_domain)=v_domain
     and sc.active=true and t.status='ACTIVE';

  if v_match_count<>1 or v_match_tenant_id is distinct from new.tenant_id then
    raise exception 'SHOPIFY_WEBHOOK_CONNECTION_NOT_UNIQUE_OR_INACTIVE' using errcode='23514';
  end if;

  new.shopify_connection_id:=v_connection_id;
  new.metadata:=coalesce(new.metadata,'{}'::jsonb)
    || jsonb_build_object('shopify_connection_id',v_connection_id);
  return new;
end;
$function$;

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
  if new.source is distinct from 'shopify' then return new; end if;
  if tg_op='UPDATE'
     and new.webhook_event_id is not distinct from old.webhook_event_id
     and new.shopify_connection_id is not distinct from old.shopify_connection_id
  then return new; end if;
  if new.webhook_event_id is null then
    raise exception 'SHOPIFY_CANONICAL_EVENT_WEBHOOK_REFERENCE_REQUIRED' using errcode='23514';
  end if;

  select w.shopify_connection_id,w.tenant_id
    into v_connection_id,v_tenant_id
    from henvalt.webhook_events w
   where w.id=new.webhook_event_id and w.source='shopify';

  if not found or v_connection_id is null or v_tenant_id is distinct from new.tenant_id then
    raise exception 'SHOPIFY_CANONICAL_EVENT_CONNECTION_SCOPE_MISSING' using errcode='23514';
  end if;
  if new.shopify_connection_id is not null
     and new.shopify_connection_id is distinct from v_connection_id then
    raise exception 'SHOPIFY_CANONICAL_EVENT_CONNECTION_SCOPE_MISMATCH' using errcode='23514';
  end if;

  new.shopify_connection_id:=v_connection_id;
  new.metadata:=coalesce(new.metadata,'{}'::jsonb)
    || jsonb_build_object('shopify_connection_id',v_connection_id);
  return new;
end;
$function$;

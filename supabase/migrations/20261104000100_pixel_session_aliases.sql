-- HENVALT Web Pixel collector foundation.
-- Review and apply only after the worker secrets and tenant key provisioning are ready.

create table if not exists henvalt.pixel_keys (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references henvalt.tenants(id) on delete cascade,
  key_digest text not null unique,
  allowed_origins text[] not null default '{}',
  active boolean not null default true,
  created_at timestamptz not null default now(),
  revoked_at timestamptz
);

create index if not exists pixel_keys_tenant_active_idx
  on henvalt.pixel_keys (tenant_id, active);

create table if not exists henvalt.session_aliases (
  tenant_id uuid not null references henvalt.tenants(id) on delete cascade,
  alias_reference text not null,
  session_reference text not null,
  created_at timestamptz not null default now(),
  primary key (tenant_id, alias_reference),
  constraint session_aliases_session_fk
    foreign key (tenant_id, session_reference)
    references henvalt.sessions (tenant_id, session_reference)
    on delete cascade,
  constraint session_aliases_alias_not_empty check (length(alias_reference) between 1 and 300),
  constraint session_aliases_session_not_empty check (length(session_reference) between 1 and 160)
);

alter table henvalt.pixel_keys enable row level security;
alter table henvalt.session_aliases enable row level security;

revoke all on henvalt.pixel_keys from public, anon, authenticated;
revoke all on henvalt.session_aliases from public, anon, authenticated;
grant select, insert, update, delete on henvalt.pixel_keys to service_role;
grant select, insert, update, delete on henvalt.session_aliases to service_role;

create or replace function henvalt.bind_session_alias(
  p_tenant_id uuid,
  p_alias_reference text,
  p_session_reference text
)
returns uuid
language plpgsql
security definer
set search_path to 'henvalt', 'public'
as $function$
declare
  v_session_id uuid;
  v_existing_session_reference text;
begin
  if p_tenant_id is null
     or p_alias_reference is null
     or length(p_alias_reference) < 1
     or length(p_alias_reference) > 300
     or p_session_reference is null
     or length(p_session_reference) < 1
     or length(p_session_reference) > 160
     or p_alias_reference = p_session_reference then
    raise exception 'Invalid session alias input';
  end if;

  if not exists (
    select 1 from henvalt.tenants t
    where t.id = p_tenant_id and t.status = 'ACTIVE'
  ) then
    raise exception 'Tenant is not active';
  end if;

  insert into henvalt.sessions (
    tenant_id, customer_id, session_reference, first_seen_at, last_seen_at
  )
  values (p_tenant_id, null, p_session_reference, now(), now())
  on conflict (tenant_id, session_reference)
  do update set last_seen_at = greatest(
    coalesce(henvalt.sessions.last_seen_at, now()), now()
  )
  returning id into v_session_id;

  select sa.session_reference
    into v_existing_session_reference
  from henvalt.session_aliases sa
  where sa.tenant_id = p_tenant_id
    and sa.alias_reference = p_alias_reference
  for update;

  if v_existing_session_reference is not null
     and v_existing_session_reference <> p_session_reference then
    raise exception 'Session alias already bound to another session';
  end if;

  insert into henvalt.session_aliases (
    tenant_id, alias_reference, session_reference
  )
  values (p_tenant_id, p_alias_reference, p_session_reference)
  on conflict (tenant_id, alias_reference) do nothing;

  -- Re-read after the insert to catch a concurrent attempt to bind this
  -- checkout token to a different browser session.
  select sa.session_reference
    into v_existing_session_reference
  from henvalt.session_aliases sa
  where sa.tenant_id = p_tenant_id
    and sa.alias_reference = p_alias_reference;

  if v_existing_session_reference <> p_session_reference then
    raise exception 'Session alias already bound to another session';
  end if;

  return v_session_id;
end;
$function$;

revoke all on function henvalt.bind_session_alias(uuid, text, text) from public, anon, authenticated;
grant execute on function henvalt.bind_session_alias(uuid, text, text) to service_role;

create or replace function henvalt.resolve_identity(p_event_id uuid)
returns table(customer_id uuid, checkout_id uuid, session_id uuid)
language plpgsql
security definer
set search_path to 'henvalt', 'public'
as $function$
declare
  v_tenant_id uuid;
  v_email text;
  v_customer_reference text;
  v_session_reference text;
  v_resolved_session_reference text;
  v_resolved_customer_id uuid;
begin
  select tenant_id, email, customer_reference, session_reference
    into v_tenant_id, v_email, v_customer_reference, v_session_reference
  from henvalt.canonical_events
  where id = p_event_id;

  if v_tenant_id is null then
    raise exception 'Canonical event not found: %', p_event_id;
  end if;

  customer_id := null;
  checkout_id := null;
  session_id := null;
  v_resolved_session_reference := v_session_reference;

  if v_customer_reference is not null then
    select c.id into customer_id
    from henvalt.customers c
    where c.tenant_id = v_tenant_id
      and c.shopify_customer_id = v_customer_reference
    limit 1;
  end if;

  if customer_id is null and v_email is not null then
    select c.id into customer_id
    from henvalt.customers c
    where c.tenant_id = v_tenant_id
      and lower(c.email) = lower(v_email)
    order by c.created_at asc
    limit 1;
  end if;

  if v_session_reference is not null then
    -- Prefer an alias when present. A checkout webhook may have arrived first
    -- and created a checkout-token session before the pixel could bind the
    -- token to its anonymous browser session.
    select sa.session_reference
      into v_resolved_session_reference
    from henvalt.session_aliases sa
    where sa.tenant_id = v_tenant_id
      and sa.alias_reference = v_session_reference
    limit 1;

    if v_resolved_session_reference is not null then
      select s.id into session_id
      from henvalt.sessions s
      where s.tenant_id = v_tenant_id
        and s.session_reference = v_resolved_session_reference
      limit 1;
    else
      v_resolved_session_reference := v_session_reference;
      select s.id into session_id
      from henvalt.sessions s
      where s.tenant_id = v_tenant_id
        and s.session_reference = v_session_reference
      limit 1;
    end if;
  end if;

  if v_session_reference is not null and session_id is null then
    insert into henvalt.sessions (
      tenant_id, customer_id, session_reference, first_seen_at, last_seen_at
    )
    values (
      v_tenant_id, customer_id, v_resolved_session_reference, now(), now()
    )
    on conflict (tenant_id, session_reference)
    do update set customer_id = coalesce(
      henvalt.sessions.customer_id, excluded.customer_id
    ), last_seen_at = now()
    returning id into session_id;
  elsif session_id is not null and customer_id is not null then
    update henvalt.sessions s
      set customer_id = coalesce(v_resolved_customer_id, s.customer_id),
          last_seen_at = now()
    where s.id = session_id;
  end if;

  v_resolved_customer_id := customer_id;

  if v_email is not null then
    select co.id into checkout_id
    from henvalt.checkouts co
    where co.tenant_id = v_tenant_id
      and lower(co.email) = lower(v_email)
      and (
        v_session_reference is null
        or co.session_reference = v_session_reference
      )
    order by co.created_at desc
    limit 1;
  end if;

  return next;
end;
$function$;

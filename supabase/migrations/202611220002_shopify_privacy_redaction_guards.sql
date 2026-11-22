-- Candidate-only guards for truthful customer matching and lease-fenced shop deletion.
-- Not applied to production.
begin;

create or replace function henvalt.redact_shopify_customer_data_checked(
  p_tenant_id uuid,
  p_shopify_customer_id text,
  p_customer_email text default null
)
returns jsonb
language plpgsql
security definer
set search_path = henvalt, pg_temp
as $function$
declare
  v_email text := nullif(lower(trim(p_customer_email)), '');
  v_customer_id text := nullif(trim(p_shopify_customer_id), '');
  v_found boolean := false;
  v_result jsonb;
begin
  if p_tenant_id is null or (v_customer_id is null and v_email is null) then
    raise exception 'tenant_id and a customer identifier are required';
  end if;

  select exists (
    select 1 from henvalt.customers c
    where c.tenant_id=p_tenant_id
      and ((v_customer_id is not null and c.shopify_customer_id=v_customer_id)
        or (v_email is not null and lower(c.email)=v_email))
    union all
    select 1 from henvalt.checkouts x
    where x.tenant_id=p_tenant_id and v_email is not null and lower(x.email)=v_email
    union all
    select 1 from henvalt.canonical_events x
    where x.tenant_id=p_tenant_id
      and ((v_customer_id is not null and (
          x.customer_reference=v_customer_id
          or x.payload #>> '{customer,id}'=v_customer_id
          or x.payload #>> '{id}'=v_customer_id
        ))
        or (v_email is not null and lower(x.email)=v_email))
    union all
    select 1 from henvalt.delivery_requests x
    where x.tenant_id=p_tenant_id and v_email is not null and lower(x.recipient_reference)=v_email
    union all
    select 1 from henvalt.messages x
    where x.tenant_id=p_tenant_id and v_email is not null and lower(x.recipient)=v_email
    union all
    select 1 from henvalt.conversation_messages x
    where x.tenant_id=p_tenant_id and v_email is not null
      and (lower(x.sender_email)=v_email or lower(x.recipient_email)=v_email)
    union all
    select 1 from henvalt.email_suppressions x
    where x.tenant_id=p_tenant_id and v_email is not null and lower(x.email_normalized)=v_email
    union all
    select 1 from henvalt.provider_events x
    where x.tenant_id=p_tenant_id and v_email is not null and lower(x.recipient_email)=v_email
    union all
    select 1 from henvalt.recovery_interventions x
    where x.tenant_id=p_tenant_id and v_email is not null and lower(x.recipient_reference)=v_email
    union all
    select 1 from henvalt.webhook_events x
    where x.tenant_id=p_tenant_id and (
      (v_customer_id is not null and (x.payload #>> '{customer,id}'=v_customer_id or x.payload #>> '{id}'=v_customer_id))
      or (v_email is not null and lower(coalesce(x.payload #>> '{customer,email}',x.payload #>> '{email}',''))=v_email)
    )
    union all
    select 1 from henvalt.processing_errors x
    where x.tenant_id=p_tenant_id and (
      (v_customer_id is not null and (x.payload #>> '{customer,id}'=v_customer_id or x.payload #>> '{id}'=v_customer_id))
      or (v_email is not null and lower(coalesce(x.payload #>> '{customer,email}',x.payload #>> '{email}',''))=v_email)
    )
    union all
    select 1 from henvalt.background_jobs x
    where x.tenant_id=p_tenant_id and (
      (v_customer_id is not null and (x.payload #>> '{customer,id}'=v_customer_id or x.payload #>> '{id}'=v_customer_id))
      or (v_email is not null and lower(coalesce(x.payload #>> '{customer,email}',x.payload #>> '{email}',''))=v_email)
    )
    union all
    select 1 from henvalt.audit_log x
    where x.tenant_id=p_tenant_id and (
      (v_customer_id is not null and (x.payload #>> '{customer,id}'=v_customer_id or x.payload #>> '{id}'=v_customer_id))
      or (v_email is not null and lower(coalesce(x.payload #>> '{customer,email}',x.payload #>> '{email}',''))=v_email)
    )
  ) into v_found;

  if not v_found then
    return jsonb_build_object('matched', false, 'reason', 'customer_record_not_found');
  end if;

  v_result := henvalt.redact_shopify_customer_data(p_tenant_id, v_customer_id, v_email);
  return v_result || jsonb_build_object('matched', true);
end;
$function$;

create or replace function henvalt.redact_shopify_customer_data_checked_with_lease(
  p_privacy_request_id uuid,
  p_lease_token uuid
)
returns jsonb
language plpgsql
security definer
set search_path = henvalt, pg_temp
as $function$
declare
  v_request henvalt.shopify_privacy_requests%rowtype;
  v_email text;
begin
  if p_privacy_request_id is null or p_lease_token is null then
    raise exception 'request id and lease token are required';
  end if;

  select * into v_request
  from henvalt.shopify_privacy_requests
  where id=p_privacy_request_id
  for update;

  if not found
    or v_request.topic <> 'customers/redact'
    or v_request.status <> 'PROCESSING'
    or v_request.lease_token is distinct from p_lease_token
    or v_request.lease_expires_at is null
    or v_request.lease_expires_at <= now()
    or v_request.tenant_id is null
  then
    raise exception 'privacy request lease is not current';
  end if;

  v_email := nullif(lower(trim(v_request.payload->>'customer_email')), '');
  return henvalt.redact_shopify_customer_data_checked(
    v_request.tenant_id, v_request.customer_id, v_email
  );
end;
$function$;

create or replace function henvalt.export_shopify_customer_data_with_lease(
  p_privacy_request_id uuid,
  p_lease_token uuid
)
returns jsonb
language plpgsql
security definer
set search_path = henvalt, pg_temp
as $function$
declare
  v_request henvalt.shopify_privacy_requests%rowtype;
  v_email text;
  v_result jsonb;
  v_updated integer;
begin
  if p_privacy_request_id is null or p_lease_token is null then
    raise exception 'request id and lease token are required';
  end if;

  select * into v_request
  from henvalt.shopify_privacy_requests
  where id=p_privacy_request_id
  for update;

  if not found
    or v_request.topic <> 'customers/data_request'
    or v_request.status <> 'PROCESSING'
    or v_request.lease_token is distinct from p_lease_token
    or v_request.lease_expires_at is null
    or v_request.lease_expires_at <= now()
    or v_request.tenant_id is null
  then
    raise exception 'privacy request lease is not current';
  end if;

  v_email := nullif(lower(trim(v_request.payload->>'customer_email')), '');
  v_result := henvalt.export_shopify_customer_data(
    v_request.tenant_id, v_request.customer_id, v_email
  );

  if v_result->>'found' = 'true' then
    update henvalt.shopify_privacy_requests
    set result_payload = v_result,
        result_expires_at = now() + interval '30 days'
    where id=p_privacy_request_id
      and status='PROCESSING'
      and lease_token=p_lease_token
      and lease_expires_at > now();
    get diagnostics v_updated = row_count;
    if v_updated <> 1 then
      raise exception 'privacy request lease expired while saving export';
    end if;
  else
    update henvalt.shopify_privacy_requests
    set result_payload = null, result_expires_at = null
    where id=p_privacy_request_id
      and status='PROCESSING'
      and lease_token=p_lease_token
      and lease_expires_at > now();
    get diagnostics v_updated = row_count;
    if v_updated <> 1 then
      raise exception 'privacy request lease expired while clearing export';
    end if;
  end if;

  return v_result;
end;
$function$;

create or replace function henvalt.redact_shopify_shop_data_with_lease(
  p_privacy_request_id uuid,
  p_lease_token uuid
)
returns jsonb
language plpgsql
security definer
set search_path = henvalt, pg_temp
as $function$
declare
  v_request henvalt.shopify_privacy_requests%rowtype;
  v_result jsonb;
begin
  if p_privacy_request_id is null or p_lease_token is null then
    raise exception 'request id and lease token are required';
  end if;

  select * into v_request
  from henvalt.shopify_privacy_requests
  where id=p_privacy_request_id
  for update;

  if not found
    or v_request.topic <> 'shop/redact'
    or v_request.status <> 'PROCESSING'
    or v_request.lease_token is distinct from p_lease_token
    or v_request.lease_expires_at is null
    or v_request.lease_expires_at <= now()
  then
    raise exception 'privacy request lease is not current';
  end if;

  v_result := henvalt.redact_shopify_shop_data(p_privacy_request_id);
  update henvalt.shopify_privacy_requests
  set lease_token = null, lease_expires_at = null
  where id=p_privacy_request_id and status='COMPLETED';
  return v_result;
end;
$function$;

revoke all on function henvalt.redact_shopify_customer_data_checked(uuid,text,text) from public, anon, authenticated;
revoke all on function henvalt.redact_shopify_shop_data_with_lease(uuid,uuid) from public, anon, authenticated;
revoke all on function henvalt.redact_shopify_customer_data_checked_with_lease(uuid,uuid) from public, anon, authenticated;
revoke all on function henvalt.export_shopify_customer_data_with_lease(uuid,uuid) from public, anon, authenticated;
grant execute on function henvalt.redact_shopify_customer_data_checked(uuid,text,text) to service_role;
grant execute on function henvalt.redact_shopify_shop_data_with_lease(uuid,uuid) to service_role;
grant execute on function henvalt.redact_shopify_customer_data_checked_with_lease(uuid,uuid) to service_role;
grant execute on function henvalt.export_shopify_customer_data_with_lease(uuid,uuid) to service_role;

commit;

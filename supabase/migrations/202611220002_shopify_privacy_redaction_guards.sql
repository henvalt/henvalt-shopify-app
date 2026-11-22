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
      and ((v_customer_id is not null and x.customer_reference=v_customer_id)
        or (v_email is not null and lower(x.email)=v_email))
    union all
    select 1 from henvalt.delivery_requests x
    where x.tenant_id=p_tenant_id and v_email is not null and lower(x.recipient_reference)=v_email
    union all
    select 1 from henvalt.messages x
    where x.tenant_id=p_tenant_id and v_email is not null and lower(x.recipient)=v_email
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
      (v_customer_id is not null and x.payload #>> '{customer,id}'=v_customer_id)
      or (v_email is not null and lower(coalesce(x.payload #>> '{customer,email}',x.payload #>> '{email}',''))=v_email)
    )
    union all
    select 1 from henvalt.audit_log x
    where x.tenant_id=p_tenant_id and (
      (v_customer_id is not null and x.payload #>> '{customer,id}'=v_customer_id)
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
    or v_request.lease_token <> p_lease_token
    or v_request.lease_expires_at <= now()
  then
    raise exception 'privacy request lease is not current';
  end if;

  v_result := henvalt.redact_shopify_shop_data(p_privacy_request_id);
  return v_result;
end;
$function$;

revoke all on function henvalt.redact_shopify_customer_data_checked(uuid,text,text) from public, anon, authenticated;
revoke all on function henvalt.redact_shopify_shop_data_with_lease(uuid,uuid) from public, anon, authenticated;
grant execute on function henvalt.redact_shopify_customer_data_checked(uuid,text,text) to service_role;
grant execute on function henvalt.redact_shopify_shop_data_with_lease(uuid,uuid) to service_role;

commit;

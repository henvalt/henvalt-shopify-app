-- Candidate-only privacy request lease and payload-minimization primitives.
-- Not applied to production. Requires review and isolated PostgreSQL acceptance tests.
begin;

alter table henvalt.shopify_privacy_requests
  add column if not exists lease_token uuid,
  add column if not exists lease_expires_at timestamptz,
  add column if not exists lease_attempts integer not null default 0;

alter table henvalt.shopify_privacy_requests
  add constraint shopify_privacy_requests_lease_attempts_nonnegative
  check (lease_attempts >= 0) not valid;

create index if not exists shopify_privacy_requests_claim_idx
  on henvalt.shopify_privacy_requests (status, lease_expires_at, received_at)
  where status in ('PENDING', 'FAILED', 'PROCESSING');

create or replace function henvalt.claim_shopify_privacy_request(
  p_lease_seconds integer default 120
)
returns table (
  id uuid,
  tenant_id uuid,
  shop_domain text,
  shopify_shop_id text,
  topic text,
  webhook_id text,
  customer_id text,
  request_id text,
  payload jsonb,
  lease_token uuid,
  lease_expires_at timestamptz,
  lease_attempts integer
)
language plpgsql
security definer
set search_path = henvalt, pg_temp
as $function$
declare
  v_id uuid;
  v_token uuid := gen_random_uuid();
begin
  if p_lease_seconds is null or p_lease_seconds < 15 or p_lease_seconds > 300 then
    raise exception 'lease_seconds must be between 15 and 300';
  end if;

  update henvalt.shopify_privacy_requests r
  set status = 'REVIEW_REQUIRED',
      payload = '{}'::jsonb,
      customer_id = null,
      last_error = 'retry_limit_exceeded',
      lease_token = null,
      lease_expires_at = null
  where r.status in ('FAILED', 'PROCESSING')
    and r.lease_attempts >= 8
    and (r.status = 'FAILED' or r.lease_expires_at <= now());

  select r.id into v_id
  from henvalt.shopify_privacy_requests r
  where
    (r.status = 'PENDING'
      or (r.status = 'FAILED' and r.lease_attempts < 8)
      or (r.status = 'PROCESSING' and r.lease_attempts < 8 and r.lease_expires_at <= now()))
    and (r.lease_expires_at is null or r.lease_expires_at <= now())
  order by r.received_at, r.id
  for update skip locked
  limit 1;

  if v_id is null then
    return;
  end if;

  return query
  update henvalt.shopify_privacy_requests r
  set status = 'PROCESSING',
      lease_token = v_token,
      lease_expires_at = now() + make_interval(secs => p_lease_seconds),
      lease_attempts = r.lease_attempts + 1,
      last_error = null
  where r.id = v_id
  returning r.id, r.tenant_id, r.shop_domain, r.shopify_shop_id, r.topic,
    r.webhook_id, r.customer_id, r.request_id, r.payload,
    r.lease_token, r.lease_expires_at, r.lease_attempts;
end;
$function$;

create or replace function henvalt.finish_shopify_privacy_request(
  p_request_id uuid,
  p_lease_token uuid,
  p_status text,
  p_error_code text default null
)
returns boolean
language plpgsql
security definer
set search_path = henvalt, pg_temp
as $function$
declare
  v_updated integer;
begin
  if p_request_id is null or p_lease_token is null then
    raise exception 'request id and lease token are required';
  end if;
  if p_status not in ('COMPLETED', 'FAILED', 'REVIEW_REQUIRED') then
    raise exception 'unsupported terminal status';
  end if;
  if p_error_code is not null and p_error_code !~ '^[a-z0-9_]{1,80}$' then
    raise exception 'error code must be a bounded machine identifier';
  end if;

  update henvalt.shopify_privacy_requests r
  set status = case
        when p_status = 'FAILED' and r.lease_attempts >= 8 then 'REVIEW_REQUIRED'
        else p_status
      end,
      payload = case
        when p_status in ('COMPLETED', 'REVIEW_REQUIRED')
          or (p_status = 'FAILED' and r.lease_attempts >= 8)
        then '{}'::jsonb else r.payload
      end,
      customer_id = case
        when p_status in ('COMPLETED', 'REVIEW_REQUIRED')
          or (p_status = 'FAILED' and r.lease_attempts >= 8)
        then null else r.customer_id
      end,
      processed_at = case when p_status = 'COMPLETED' then now() else r.processed_at end,
      last_error = case
        when p_status = 'FAILED' and r.lease_attempts >= 8 then 'retry_limit_exceeded'
        else p_error_code
      end,
      lease_token = null,
      lease_expires_at = null
  where r.id = p_request_id
    and r.status = 'PROCESSING'
    and r.lease_token = p_lease_token
    and r.lease_expires_at > now();

  get diagnostics v_updated = row_count;
  return v_updated = 1;
end;
$function$;

create or replace function henvalt.claim_shopify_privacy_request_by_id(
  p_request_id uuid,
  p_lease_seconds integer default 120
)
returns table (
  id uuid,
  tenant_id uuid,
  shop_domain text,
  shopify_shop_id text,
  topic text,
  webhook_id text,
  customer_id text,
  request_id text,
  payload jsonb,
  lease_token uuid,
  lease_expires_at timestamptz,
  lease_attempts integer
)
language plpgsql
security definer
set search_path = henvalt, pg_temp
as $function$
declare
  v_token uuid := gen_random_uuid();
begin
  if p_request_id is null then
    raise exception 'request_id is required';
  end if;
  if p_lease_seconds is null or p_lease_seconds < 15 or p_lease_seconds > 300 then
    raise exception 'lease_seconds must be between 15 and 300';
  end if;

  update henvalt.shopify_privacy_requests r
  set status = 'REVIEW_REQUIRED',
      payload = '{}'::jsonb,
      customer_id = null,
      last_error = 'retry_limit_exceeded',
      lease_token = null,
      lease_expires_at = null
  where r.id = p_request_id
    and r.status in ('FAILED', 'PROCESSING')
    and r.lease_attempts >= 8
    and (r.status = 'FAILED' or r.lease_expires_at <= now());

  return query
  update henvalt.shopify_privacy_requests r
  set status = 'PROCESSING',
      lease_token = v_token,
      lease_expires_at = now() + make_interval(secs => p_lease_seconds),
      lease_attempts = r.lease_attempts + 1,
      last_error = null
  where r.id = p_request_id
    and (r.status = 'PENDING'
      or (r.status = 'FAILED' and r.lease_attempts < 8)
      or (r.status = 'PROCESSING' and r.lease_attempts < 8 and r.lease_expires_at <= now()))
    and (r.lease_expires_at is null or r.lease_expires_at <= now())
  returning r.id, r.tenant_id, r.shop_domain, r.shopify_shop_id, r.topic,
    r.webhook_id, r.customer_id, r.request_id, r.payload,
    r.lease_token, r.lease_expires_at, r.lease_attempts;
end;
$function$;

revoke all on function henvalt.claim_shopify_privacy_request(integer) from public, anon, authenticated;
revoke all on function henvalt.finish_shopify_privacy_request(uuid, uuid, text, text) from public, anon, authenticated;
revoke all on function henvalt.claim_shopify_privacy_request_by_id(uuid, integer) from public, anon, authenticated;
grant execute on function henvalt.claim_shopify_privacy_request(integer) to service_role;
grant execute on function henvalt.finish_shopify_privacy_request(uuid, uuid, text, text) to service_role;
grant execute on function henvalt.claim_shopify_privacy_request_by_id(uuid, integer) to service_role;

commit;

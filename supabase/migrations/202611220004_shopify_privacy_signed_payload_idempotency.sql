-- Candidate-only idempotency based on HMAC-covered bytes, not unsigned webhook headers.
begin;

alter table henvalt.shopify_privacy_requests
  add column if not exists signed_payload_hash text;

alter table henvalt.shopify_privacy_requests
  add constraint shopify_privacy_requests_signed_payload_hash_check
  check (signed_payload_hash is null or signed_payload_hash ~ '^[a-f0-9]{64}$') not valid;

create unique index if not exists shopify_privacy_requests_signed_payload_idx
  on henvalt.shopify_privacy_requests (shop_domain, topic, signed_payload_hash)
  where signed_payload_hash is not null;

create or replace function henvalt.persist_shopify_privacy_request(
  p_tenant_id uuid,
  p_shop_domain text,
  p_shopify_shop_id text,
  p_topic text,
  p_webhook_id text,
  p_signed_payload_hash text,
  p_customer_id text,
  p_request_id text,
  p_payload jsonb,
  p_status text
)
returns table (id uuid, status text)
language plpgsql
security definer
set search_path = henvalt, pg_temp
as $function$
declare
  v_id uuid;
  v_status text;
  v_hash text;
begin
  if p_shop_domain is null or p_shop_domain !~ '^[a-z0-9][a-z0-9-]*\.myshopify\.com$'
    or p_topic is null or p_topic not in ('customers/data_request','customers/redact','shop/redact')
    or p_shopify_shop_id is null or length(p_shopify_shop_id) < 1
    or p_webhook_id is null or length(p_webhook_id) < 1 or length(p_webhook_id) > 128
    or p_signed_payload_hash is null or p_signed_payload_hash !~ '^[a-f0-9]{64}$'
    or p_payload is null
    or p_status is null or p_status not in ('PENDING','REVIEW_REQUIRED')
  then
    raise exception 'invalid privacy receipt';
  end if;

  select r.id,r.status,r.signed_payload_hash
    into v_id,v_status,v_hash
  from henvalt.shopify_privacy_requests r
  where r.webhook_id=p_webhook_id
  for update;

  if found then
    if v_hash is distinct from p_signed_payload_hash then
      raise exception 'webhook_id_payload_mismatch';
    end if;
    return query select v_id,v_status;
    return;
  end if;

  select r.id,r.status
    into v_id,v_status
  from henvalt.shopify_privacy_requests r
  where r.shop_domain=p_shop_domain
    and r.topic=p_topic
    and r.signed_payload_hash=p_signed_payload_hash
  for update;

  if found then
    return query select v_id,v_status;
    return;
  end if;

  insert into henvalt.shopify_privacy_requests (
    tenant_id,shop_domain,shopify_shop_id,topic,webhook_id,
    signed_payload_hash,customer_id,request_id,payload,status
  ) values (
    p_tenant_id,p_shop_domain,p_shopify_shop_id,p_topic,p_webhook_id,
    p_signed_payload_hash,p_customer_id,p_request_id,p_payload,p_status
  )
  on conflict do nothing
  returning shopify_privacy_requests.id,shopify_privacy_requests.status
    into v_id,v_status;

  if found then
    return query select v_id,v_status;
    return;
  end if;

  -- Resolve a concurrent insert without trusting the unsigned webhook ID.
  select r.id,r.status,r.signed_payload_hash
    into v_id,v_status,v_hash
  from henvalt.shopify_privacy_requests r
  where r.webhook_id=p_webhook_id
  for update;

  if found then
    if v_hash is distinct from p_signed_payload_hash then
      raise exception 'webhook_id_payload_mismatch';
    end if;
    return query select v_id,v_status;
    return;
  end if;

  select r.id,r.status
    into v_id,v_status
  from henvalt.shopify_privacy_requests r
  where r.shop_domain=p_shop_domain
    and r.topic=p_topic
    and r.signed_payload_hash=p_signed_payload_hash
  for update;

  if found then
    return query select v_id,v_status;
    return;
  end if;

  raise exception 'privacy_receipt_persist_race_unresolved';
end;
$function$;

revoke all on function henvalt.persist_shopify_privacy_request(uuid,text,text,text,text,text,text,text,jsonb,text) from public, anon, authenticated;
grant execute on function henvalt.persist_shopify_privacy_request(uuid,text,text,text,text,text,text,text,jsonb,text) to service_role;

commit;

-- Fail closed for Shopify privacy redaction until records are connection-scoped.
-- The current tenant-wide redaction routines can affect sibling Shopify stores.
-- This migration deliberately does NOT delete or anonymize tenant data.
-- The queue worker will retry boundedly and then move the request to REVIEW_REQUIRED.

create or replace function henvalt.redact_shopify_customer_data_checked_with_lease(
  p_privacy_request_id uuid,
  p_lease_token uuid
) returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, henvalt, pg_temp
as $function$
declare
  v_request henvalt.shopify_privacy_requests%rowtype;
begin
  if p_privacy_request_id is null or p_lease_token is null then
    raise exception 'request id and lease token are required';
  end if;

  select * into v_request
  from henvalt.shopify_privacy_requests
  where id = p_privacy_request_id
  for update;

  if not found
    or v_request.topic <> 'customers/redact'
    or v_request.status <> 'PROCESSING'
    or v_request.lease_token is distinct from p_lease_token
    or v_request.lease_expires_at is null
    or v_request.lease_expires_at <= now()
  then
    raise exception 'privacy request lease is not current';
  end if;

  -- Customer rows/events do not yet carry an authoritative Shopify connection
  -- foreign key. Tenant-only matching is unsafe when a tenant has multiple shops.
  return jsonb_build_object(
    'matched', false,
    'review_required', true,
    'reason', 'connection_scoped_customer_redaction_not_implemented'
  );
end;
$function$;

create or replace function henvalt.redact_shopify_shop_data_with_lease(
  p_privacy_request_id uuid,
  p_lease_token uuid
) returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, henvalt, pg_temp
as $function$
declare
  v_request henvalt.shopify_privacy_requests%rowtype;
begin
  if p_privacy_request_id is null or p_lease_token is null then
    raise exception 'request id and lease token are required';
  end if;

  select * into v_request
  from henvalt.shopify_privacy_requests
  where id = p_privacy_request_id
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

  -- Never call redact_shopify_shop_data here: it deletes the whole tenant.
  -- The queue worker treats this non-completion as retryable and eventually
  -- moves the request to REVIEW_REQUIRED; no tenant or sibling shop is deleted.
  return jsonb_build_object(
    'completed', false,
    'review_required', true,
    'reason', 'connection_scoped_shop_redaction_not_implemented'
  );
end;
$function$;

revoke all on function henvalt.redact_shopify_customer_data_checked_with_lease(uuid, uuid)
  from public, anon, authenticated;
revoke all on function henvalt.redact_shopify_shop_data_with_lease(uuid, uuid)
  from public, anon, authenticated;
grant execute on function henvalt.redact_shopify_customer_data_checked_with_lease(uuid, uuid)
  to service_role;
grant execute on function henvalt.redact_shopify_shop_data_with_lease(uuid, uuid)
  to service_role;

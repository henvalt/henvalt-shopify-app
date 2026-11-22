-- Candidate-only merchant export download acknowledgement.
-- The server no longer marks result_delivered_at before the response reaches the dashboard.
begin;

alter table henvalt.shopify_privacy_requests
  add column if not exists result_download_started_at timestamptz,
  add column if not exists result_delivery_ack_token_hash text,
  add column if not exists result_delivery_ack_expires_at timestamptz,
  add column if not exists result_client_acknowledged_at timestamptz;

alter table henvalt.shopify_privacy_requests
  add constraint shopify_privacy_requests_delivery_ack_hash_check
  check (
    result_delivery_ack_token_hash is null
    or result_delivery_ack_token_hash ~ '^[a-f0-9]{64}$'
  ) not valid;

create index if not exists shopify_privacy_requests_export_ack_idx
  on henvalt.shopify_privacy_requests
    (tenant_id, result_expires_at, result_delivery_ack_expires_at)
  where topic='customers/data_request' and status='REVIEW_REQUIRED';

create or replace function henvalt.acknowledge_shopify_privacy_export_download(
  p_request_id uuid,
  p_tenant_id uuid,
  p_token_hash text
)
returns boolean
language plpgsql
security definer
set search_path = henvalt, pg_temp
as $function$
declare
  v_updated integer;
begin
  if p_request_id is null or p_tenant_id is null
     or p_token_hash is null or p_token_hash !~ '^[a-f0-9]{64}$' then
    raise exception 'invalid privacy export acknowledgement';
  end if;

  update henvalt.shopify_privacy_requests r
  set result_client_acknowledged_at = coalesce(r.result_client_acknowledged_at, now()),
      result_delivery_ack_token_hash = null,
      result_delivery_ack_expires_at = null
  where r.id = p_request_id
    and r.tenant_id = p_tenant_id
    and r.topic = 'customers/data_request'
    and r.status = 'REVIEW_REQUIRED'
    and r.result_payload is not null
    and r.result_expires_at > now()
    and r.result_delivery_ack_token_hash = p_token_hash
    and r.result_delivery_ack_expires_at > now();

  get diagnostics v_updated = row_count;
  return v_updated = 1;
end;
$function$;

revoke all on function henvalt.acknowledge_shopify_privacy_export_download(uuid,uuid,text) from public, anon, authenticated;
grant execute on function henvalt.acknowledge_shopify_privacy_export_download(uuid,uuid,text) to service_role;

commit;

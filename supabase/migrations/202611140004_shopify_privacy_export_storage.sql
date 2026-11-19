-- Securely retain customer export results for merchant delivery.
-- Export results contain personal data and remain service-role only.
alter table henvalt.shopify_privacy_requests
  add column if not exists result_payload jsonb,
  add column if not exists result_expires_at timestamptz,
  add column if not exists result_delivered_at timestamptz;

create index if not exists shopify_privacy_requests_export_expiry_idx
  on henvalt.shopify_privacy_requests (result_expires_at)
  where result_payload is not null;

revoke all on henvalt.shopify_privacy_requests from public, anon, authenticated;
grant select, insert, update on henvalt.shopify_privacy_requests to service_role;

create or replace function henvalt.purge_expired_shopify_privacy_exports()
returns integer
language plpgsql
security definer
set search_path = henvalt, pg_temp
as $purge$
declare
  v_count integer;
begin
  update henvalt.shopify_privacy_requests
  set result_payload = null, result_expires_at = null
  where result_payload is not null and result_expires_at <= now();
  get diagnostics v_count = row_count;
  return v_count;
end;
$purge$;

revoke all on function henvalt.purge_expired_shopify_privacy_exports() from public, anon, authenticated;
grant execute on function henvalt.purge_expired_shopify_privacy_exports() to service_role;

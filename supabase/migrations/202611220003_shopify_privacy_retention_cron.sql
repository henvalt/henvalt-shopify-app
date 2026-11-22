-- Candidate-only retention job. Daily cleanup bounds privacy-request identifier retention.
-- The cron schedule is created only where pg_cron is already installed.
begin;

create or replace function henvalt.purge_stale_shopify_privacy_request_identifiers()
returns jsonb
language plpgsql
security definer
set search_path = henvalt, pg_temp
as $function$
declare
  v_requests integer := 0;
  v_exports integer := 0;
begin
  update henvalt.shopify_privacy_requests r
  set status = 'REVIEW_REQUIRED',
      payload = '{}'::jsonb,
      customer_id = null,
      lease_token = null,
      lease_expires_at = null,
      next_attempt_at = null,
      last_error = 'privacy_request_retention_expired'
  where r.status in ('PENDING', 'FAILED', 'PROCESSING')
    and r.received_at < now() - interval '7 days'
    and (r.status <> 'PROCESSING' or r.lease_expires_at is null or r.lease_expires_at <= now());
  get diagnostics v_requests = row_count;

  update henvalt.shopify_privacy_requests r
  set result_payload = null,
      result_expires_at = null,
      result_delivery_ack_token_hash = null,
      result_delivery_ack_expires_at = null
  where r.result_payload is not null
    and (r.result_expires_at is null or r.result_expires_at <= now());
  get diagnostics v_exports = row_count;

  return jsonb_build_object(
    'requests_minimized', v_requests,
    'exports_expired', v_exports,
    'completed_at', now()
  );
end;
$function$;

revoke all on function henvalt.purge_stale_shopify_privacy_request_identifiers() from public, anon, authenticated;
grant execute on function henvalt.purge_stale_shopify_privacy_request_identifiers() to service_role;

do $$
declare
  v_job_id bigint;
begin
  if to_regnamespace('cron') is not null then
    execute 'select jobid from cron.job where jobname = $1 limit 1'
      into v_job_id using 'henvalt-shopify-privacy-retention';
    if v_job_id is not null then
      execute 'select cron.unschedule($1)' using v_job_id;
    end if;
    perform cron.schedule(
      'henvalt-shopify-privacy-retention',
      '17 3 * * *',
      'select henvalt.purge_stale_shopify_privacy_request_identifiers();'
    );
  end if;
end $$;

commit;

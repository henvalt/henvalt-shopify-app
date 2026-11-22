-- Candidate-only durable privacy queue processor.
-- Keeps Shopify's HTTP webhook acknowledgement separate from multi-table processing.
begin;

create or replace function henvalt.process_shopify_privacy_queue(
  p_batch_size integer default 5,
  p_lease_seconds integer default 120
)
returns jsonb
language plpgsql
security definer
set search_path = henvalt, pg_temp
as $function$
declare
  v_claim record;
  v_result jsonb;
  v_status text;
  v_error text;
  v_finished boolean;
  v_processed integer := 0;
  v_completed integer := 0;
  v_review_required integer := 0;
  v_failed integer := 0;
  v_found boolean;
  v_matched boolean;
begin
  if p_batch_size is null or p_batch_size < 1 or p_batch_size > 20 then
    raise exception 'batch_size must be between 1 and 20';
  end if;
  if p_lease_seconds is null or p_lease_seconds < 15 or p_lease_seconds > 300 then
    raise exception 'lease_seconds must be between 15 and 300';
  end if;

  for i in 1..p_batch_size loop
    select * into v_claim
    from henvalt.claim_shopify_privacy_request(p_lease_seconds);

    if v_claim.id is null then
      exit;
    end if;

    v_processed := v_processed + 1;
    begin
      if v_claim.topic = 'customers/data_request' then
        v_result := henvalt.export_shopify_customer_data_with_lease(
          v_claim.id, v_claim.lease_token
        );
        v_found := v_result->>'found' = 'true';
        v_finished := henvalt.finish_shopify_privacy_request(
          v_claim.id,
          v_claim.lease_token,
          'REVIEW_REQUIRED',
          case when v_found then 'export_ready_for_secure_merchant_delivery'
            else 'customer_record_not_found' end
        );
        if not v_finished then raise exception 'privacy export lease lost'; end if;
        v_review_required := v_review_required + 1;

      elsif v_claim.topic = 'customers/redact' then
        v_result := henvalt.redact_shopify_customer_data_checked_with_lease(
          v_claim.id, v_claim.lease_token
        );
        v_matched := v_result->>'matched' = 'true';
        v_finished := henvalt.finish_shopify_privacy_request(
          v_claim.id,
          v_claim.lease_token,
          case when v_matched then 'COMPLETED' else 'REVIEW_REQUIRED' end,
          case when v_matched then null else 'customer_record_not_found' end
        );
        if not v_finished then raise exception 'customer redaction lease lost'; end if;
        if v_matched then
          v_completed := v_completed + 1;
        else
          v_review_required := v_review_required + 1;
        end if;

      elsif v_claim.topic = 'shop/redact' then
        v_result := henvalt.redact_shopify_shop_data_with_lease(
          v_claim.id, v_claim.lease_token
        );
        select r.status into v_status
        from henvalt.shopify_privacy_requests r where r.id=v_claim.id;
        if v_status <> 'COMPLETED' then raise exception 'shop redaction did not complete'; end if;
        v_completed := v_completed + 1;

      else
        v_finished := henvalt.finish_shopify_privacy_request(
          v_claim.id, v_claim.lease_token, 'REVIEW_REQUIRED', 'unsupported_privacy_topic'
        );
        if not v_finished then raise exception 'unsupported-topic lease lost'; end if;
        v_review_required := v_review_required + 1;
      end if;

    exception when others then
      v_error := 'privacy_worker_processing_exception';
      v_finished := henvalt.finish_shopify_privacy_request(
        v_claim.id, v_claim.lease_token, 'FAILED', v_error
      );
      v_failed := v_failed + 1;
    end;
  end loop;

  return jsonb_build_object(
    'processed', v_processed,
    'completed', v_completed,
    'review_required', v_review_required,
    'failed', v_failed,
    'finished_at', now()
  );
end;
$function$;

revoke all on function henvalt.process_shopify_privacy_queue(integer,integer) from public, anon, authenticated;
grant execute on function henvalt.process_shopify_privacy_queue(integer,integer) to service_role;

do $$
declare
  v_job_id bigint;
begin
  if to_regnamespace('cron') is not null then
    execute 'select jobid from cron.job where jobname = $1 limit 1'
      into v_job_id using 'henvalt-shopify-privacy-queue-worker';
    if v_job_id is not null then
      execute 'select cron.unschedule($1)' using v_job_id;
    end if;
    perform cron.schedule(
      'henvalt-shopify-privacy-queue-worker',
      '* * * * *',
      'select henvalt.process_shopify_privacy_queue(5,120);'
    );
  end if;
end $$;

commit;

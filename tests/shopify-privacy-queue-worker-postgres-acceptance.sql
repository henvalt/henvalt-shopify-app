\set ON_ERROR_STOP on
begin;

insert into henvalt.customers(tenant_id,shopify_customer_id,email)
values ('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa','worker-customer','worker@example.test');

insert into henvalt.shopify_privacy_requests
  (id,tenant_id,shop_domain,shopify_shop_id,topic,webhook_id,customer_id,payload,status)
values
  ('10101010-1010-4010-8010-101010101010','aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
   'fixture.myshopify.com','1','customers/redact','worker-customer-redact','worker-customer',
   '{"shop_id":"1","customer_email":"worker@example.test"}'::jsonb,'PENDING'),
  ('20202020-2020-4020-8020-202020202020','aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
   'fixture.myshopify.com','1','customers/data_request','worker-customer-export','export-yes',
   '{"shop_id":"1","customer_email":"export@example.test"}'::jsonb,'PENDING'),
  ('30303030-3030-4030-8030-303030303030','aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
   'fixture.myshopify.com','1','shop/redact','worker-shop-redact',null,
   '{"shop_id":"1"}'::jsonb,'PENDING'),
  ('40404040-4040-4040-8040-404040404040','aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
   'fixture.myshopify.com','1','customers/redact','worker-customer-no-match','absent-customer',
   '{"shop_id":"1","customer_email":"absent@example.test"}'::jsonb,'PENDING'),
  ('50505050-5050-4050-8050-505050505050','aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
   'fixture.myshopify.com','1','customers/data_request','worker-export-failure','export-fail',
   '{"shop_id":"1","customer_email":"export-fail@example.test"}'::jsonb,'PENDING');

do $$
declare
  v_result jsonb;
  v_status text;
  v_payload jsonb;
  v_customer text;
  v_export jsonb;
  v_expiry timestamptz;
  v_tenant uuid;
  v_lease uuid;
  v_calls integer;
  v_rejected boolean := false;
  v_job_schedule text;
  v_job_command text;
  v_retry_at timestamptz;
  v_attempts integer;
begin
  select schedule,command into v_job_schedule,v_job_command
  from cron.job where jobname='henvalt-shopify-privacy-queue-worker';
  if v_job_schedule <> '* * * * *'
     or v_job_command <> 'select henvalt.process_shopify_privacy_queue(5,120);' then
    raise exception 'privacy worker cron schedule missing or misconfigured';
  end if;

  v_result := henvalt.process_shopify_privacy_queue(10,120);
  if (v_result->>'processed')::integer <> 5
     or (v_result->>'completed')::integer <> 2
     or (v_result->>'review_required')::integer <> 2
     or (v_result->>'failed')::integer <> 1 then
    raise exception 'privacy queue worker metrics are incorrect: %',v_result;
  end if;

  select status,payload,customer_id into v_status,v_payload,v_customer
  from henvalt.shopify_privacy_requests
  where id='10101010-1010-4010-8010-101010101010';
  if v_status <> 'COMPLETED' or v_payload <> '{}'::jsonb or v_customer is not null then
    raise exception 'worker customer redaction did not complete and minimize identifiers';
  end if;

  select status,payload,customer_id,result_payload,result_expires_at
    into v_status,v_payload,v_customer,v_export,v_expiry
  from henvalt.shopify_privacy_requests
  where id='20202020-2020-4020-8020-202020202020';
  if v_status <> 'REVIEW_REQUIRED' or v_payload <> '{}'::jsonb or v_customer is not null
     or v_export is null or v_expiry <= now() then
    raise exception 'worker export was not stored with expiry and held for secure delivery';
  end if;

  select status,tenant_id,payload,lease_token
    into v_status,v_tenant,v_payload,v_lease
  from henvalt.shopify_privacy_requests
  where id='30303030-3030-4030-8030-303030303030';
  if v_status <> 'COMPLETED' or v_tenant is not null
     or v_payload <> '{}'::jsonb or v_lease is not null then
    raise exception 'worker shop redaction did not complete and sanitize the receipt';
  end if;

  select status,payload,customer_id into v_status,v_payload,v_customer
  from henvalt.shopify_privacy_requests
  where id='40404040-4040-4040-8040-404040404040';
  if v_status <> 'REVIEW_REQUIRED' or v_payload <> '{}'::jsonb or v_customer is not null then
    raise exception 'worker no-match redaction did not move to review and minimize identifiers';
  end if;

  select status,payload,customer_id,next_attempt_at,lease_attempts
    into v_status,v_payload,v_customer,v_retry_at,v_attempts
  from henvalt.shopify_privacy_requests
  where id='50505050-5050-4050-8050-505050505050';
  if v_status <> 'FAILED' or v_payload = '{}'::jsonb or v_customer <> 'export-fail'
     or v_retry_at is null or v_retry_at <= now() or v_attempts <> 1 then
    raise exception 'worker failure did not preserve bounded retry identifiers and delay';
  end if;

  -- A due retry is processed once; a newly failed request is not immediately reclaimed again.
  update henvalt.shopify_privacy_requests
  set next_attempt_at=now()-interval '1 second'
  where id='50505050-5050-4050-8050-505050505050';
  v_result := henvalt.process_shopify_privacy_queue(5,120);
  if (v_result->>'processed')::integer <> 1
     or (v_result->>'failed')::integer <> 1 then
    raise exception 'due privacy retry was not processed exactly once: %',v_result;
  end if;
  select next_attempt_at,lease_attempts into v_retry_at,v_attempts
  from henvalt.shopify_privacy_requests
  where id='50505050-5050-4050-8050-505050505050';
  if v_retry_at is null or v_retry_at <= now() or v_attempts <> 2 then
    raise exception 'privacy retry did not schedule the next exponential delay';
  end if;

  select count(*) into v_calls from henvalt.privacy_redaction_calls;
  if v_calls <> 1 then raise exception 'worker dispatched wrong number of destructive customer redactions'; end if;

  begin
    perform henvalt.process_shopify_privacy_queue(21,120);
  exception when others then
    v_rejected := true;
  end;
  if not v_rejected then raise exception 'worker accepted batch size above hard cap'; end if;
end $$;

rollback;

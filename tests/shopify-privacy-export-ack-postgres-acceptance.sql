\set ON_ERROR_STOP on
begin;

insert into henvalt.shopify_privacy_requests
  (id,tenant_id,shop_domain,shopify_shop_id,topic,webhook_id,customer_id,payload,status,
   result_payload,result_expires_at,result_delivery_ack_token_hash,result_delivery_ack_expires_at)
values
  ('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa1','bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbb1',
   'fixture.myshopify.com','1','customers/data_request','export-ack-valid',null,'{}','REVIEW_REQUIRED',
   '{"customer":{"id":"redacted"}}'::jsonb,now()+interval '1 day',repeat('a',64),now()+interval '5 minutes'),
  ('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa2','bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbb1',
   'fixture.myshopify.com','1','customers/data_request','export-ack-expired',null,'{}','REVIEW_REQUIRED',
   '{"customer":{"id":"redacted"}}'::jsonb,now()+interval '1 day',repeat('b',64),now()-interval '1 second'),
  ('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa3','bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbb1',
   'fixture.myshopify.com','1','customers/data_request','export-ack-cleanup',null,'{}','REVIEW_REQUIRED',
   '{"customer":{"id":"redacted"}}'::jsonb,now()+interval '1 day',repeat('c',64),now()-interval '1 second');

do $ack$
declare
  v_ok boolean;
  v_ack timestamptz;
  v_hash text;
  v_expires timestamptz;
  v_delivered timestamptz;
  v_schedule text;
  v_command text;
  v_function text := 'henvalt.acknowledge_shopify_privacy_export_download(uuid,uuid,text)';
begin
  select schedule,command into strict v_schedule,v_command
  from cron.job where jobname='henvalt-shopify-privacy-export-ack-cleanup';
  if v_schedule <> '*/15 * * * *'
     or v_command <> 'select henvalt.purge_expired_shopify_privacy_export_ack_tokens();' then
    raise exception 'privacy export acknowledgement cleanup schedule missing';
  end if;

  v_ok := henvalt.acknowledge_shopify_privacy_export_download(
    'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa1',
    'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbb1',
    repeat('a',64)
  );
  if not v_ok then raise exception 'valid owner-scoped acknowledgement was rejected'; end if;

  select result_client_acknowledged_at,result_delivery_ack_token_hash,
         result_delivery_ack_expires_at,result_delivered_at
    into v_ack,v_hash,v_expires,v_delivered
  from henvalt.shopify_privacy_requests
  where id='aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa1';
  if v_ack is null or v_hash is not null or v_expires is not null or v_delivered is not null then
    raise exception 'client acknowledgement did not clear one-time token or incorrectly set legacy delivered timestamp';
  end if;

  v_ok := henvalt.acknowledge_shopify_privacy_export_download(
    'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa1',
    'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbb1',
    repeat('a',64)
  );
  if v_ok then raise exception 'one-time acknowledgement token was replayable'; end if;

  v_ok := henvalt.acknowledge_shopify_privacy_export_download(
    'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa2',
    'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbb1',
    repeat('b',64)
  );
  if v_ok then raise exception 'expired acknowledgement token was accepted'; end if;

  v_ok := henvalt.acknowledge_shopify_privacy_export_download(
    'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa3',
    'cccccccc-cccc-4ccc-8ccc-ccccccccccc3',
    repeat('c',64)
  );
  if v_ok then raise exception 'cross-tenant acknowledgement was accepted'; end if;

  perform henvalt.purge_expired_shopify_privacy_export_ack_tokens();
  select result_delivery_ack_token_hash into v_hash
  from henvalt.shopify_privacy_requests
  where id='aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa3';
  if v_hash is not null then raise exception 'expired acknowledgement token was not purged'; end if;

  if not has_function_privilege('service_role',v_function,'EXECUTE')
     or has_function_privilege('anon',v_function,'EXECUTE')
     or has_function_privilege('authenticated',v_function,'EXECUTE') then
    raise exception 'export acknowledgement RPC privileges are not restricted';
  end if;
end
$ack$;

rollback;

\set ON_ERROR_STOP on
begin;
do $$
declare
  v_first record;
  v_duplicate record;
  v_conflict boolean := false;
  v_distinct record;
begin
  select * into v_first from henvalt.persist_shopify_privacy_request(
    'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
    'fixture.myshopify.com','1','customers/redact','privacy-idem-1',
    repeat('a',64),'customer-1','request-1',
    '{"shop_id":1,"customer_email":"private@example.test"}'::jsonb,'PENDING'
  );
  if v_first.id is null or v_first.status <> 'PENDING' then
    raise exception 'first signed privacy receipt was not persisted';
  end if;

  select * into v_duplicate from henvalt.persist_shopify_privacy_request(
    'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
    'fixture.myshopify.com','1','customers/redact','privacy-idem-1',
    repeat('a',64),'customer-1','request-1',
    '{"shop_id":1,"customer_email":"private@example.test"}'::jsonb,'PENDING'
  );
  if v_duplicate.id <> v_first.id then
    raise exception 'same webhook ID and signed hash created duplicate row';
  end if;

  select * into v_duplicate from henvalt.persist_shopify_privacy_request(
    'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
    'fixture.myshopify.com','1','customers/redact','privacy-idem-2',
    repeat('a',64),'customer-1','request-1',
    '{"shop_id":1,"customer_email":"private@example.test"}'::jsonb,'PENDING'
  );
  if v_duplicate.id <> v_first.id then
    raise exception 'same signed body with a different webhook ID was not deduplicated';
  end if;

  begin
    perform * from henvalt.persist_shopify_privacy_request(
      'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
      'fixture.myshopify.com','1','customers/redact','privacy-idem-1',
      repeat('b',64),'customer-2','request-2',
      '{"shop_id":1,"customer_email":"other@example.test"}'::jsonb,'PENDING'
    );
  exception when others then
    if sqlerrm = 'webhook_id_payload_mismatch' then
      v_conflict := true;
    else
      raise;
    end if;
  end;
  if not v_conflict then raise exception 'webhook ID reuse with different signed body was accepted'; end if;

  select * into v_distinct from henvalt.persist_shopify_privacy_request(
    'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
    'fixture.myshopify.com','1','customers/redact','privacy-idem-3',
    repeat('c',64),'customer-3','request-3',
    '{"shop_id":1,"customer_email":"third@example.test"}'::jsonb,'PENDING'
  );
  if v_distinct.id is null or v_distinct.id = v_first.id then
    raise exception 'different signed body incorrectly deduplicated';
  end if;

  if (select count(*) from henvalt.shopify_privacy_requests) <> 2 then
    raise exception 'signed-payload deduplication row count is incorrect';
  end if;
end $$;
rollback;

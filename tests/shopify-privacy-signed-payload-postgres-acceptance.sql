\set ON_ERROR_STOP on
begin;

do $$
declare
  v_first record;
  v_replay record;
  v_second record;
  v_count integer;
  v_rejected boolean;
begin
  select * into v_first from henvalt.persist_shopify_privacy_request(
    'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
    'fixture.myshopify.com','1','customers/redact','unsigned-webhook-a',
    repeat('a',64),'12345',null,'{"customer_email":"minimal@example.test"}','PENDING'
  );
  if v_first.id is null then raise exception 'initial signed receipt was not persisted'; end if;

  -- A different unsigned webhook ID with identical signed bytes is the same request.
  select * into v_replay from henvalt.persist_shopify_privacy_request(
    'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
    'fixture.myshopify.com','1','customers/redact','unsigned-webhook-b',
    repeat('a',64),'12345',null,'{"customer_email":"minimal@example.test"}','PENDING'
  );
  if v_replay.id <> v_first.id then
    raise exception 'unsigned webhook ID bypassed signed-body idempotency';
  end if;

  -- Reusing one webhook ID for different signed bytes is rejected.
  v_rejected := false;
  begin
    perform * from henvalt.persist_shopify_privacy_request(
      'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
      'fixture.myshopify.com','1','customers/redact','unsigned-webhook-a',
      repeat('b',64),'12345',null,'{}','PENDING'
    );
  exception when others then
    v_rejected := true;
  end;
  if not v_rejected then raise exception 'webhook ID with changed body was accepted'; end if;

  -- Distinct signed bodies remain distinct receipts.
  select * into v_second from henvalt.persist_shopify_privacy_request(
    'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
    'fixture.myshopify.com','1','customers/redact','unsigned-webhook-c',
    repeat('b',64),'67890',null,'{}','PENDING'
  );
  if v_second.id is null or v_second.id = v_first.id then
    raise exception 'distinct signed body was incorrectly deduplicated';
  end if;

  select count(*) into v_count from henvalt.shopify_privacy_requests
  where shop_domain='fixture.myshopify.com' and topic='customers/redact';
  if v_count <> 2 then raise exception 'signed receipt count incorrect: %',v_count; end if;
end $$;

rollback;

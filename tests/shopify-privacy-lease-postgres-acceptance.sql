\set ON_ERROR_STOP on
begin;
insert into henvalt.shopify_privacy_requests
  (tenant_id,shop_domain,topic,webhook_id,customer_id,payload,status)
values
  ('11111111-1111-4111-8111-111111111111','fixture.myshopify.com',
   'customers/redact','privacy-fixture-1','998877',
   '{"customer":{"id":998877,"email":"private@example.test"}}'::jsonb,'PENDING');

do $$
declare
  v_claim record;
  v_second_count integer;
  v_finished boolean;
  v_payload jsonb;
  v_customer text;
begin
  select * into v_claim from henvalt.claim_shopify_privacy_request(120);
  if v_claim.id is null or v_claim.lease_token is null or v_claim.lease_attempts <> 1 then
    raise exception 'first atomic claim failed';
  end if;

  select count(*) into v_second_count from henvalt.claim_shopify_privacy_request(120);
  if v_second_count <> 0 then
    raise exception 'duplicate concurrent claim was not excluded';
  end if;

  v_finished := henvalt.finish_shopify_privacy_request(
    v_claim.id, gen_random_uuid(), 'COMPLETED', null
  );
  if v_finished then raise exception 'stale lease token unexpectedly finished request'; end if;

  v_finished := henvalt.finish_shopify_privacy_request(
    v_claim.id, v_claim.lease_token, 'COMPLETED', null
  );
  if not v_finished then raise exception 'valid lease failed to finish request'; end if;

  select payload,customer_id into v_payload,v_customer
  from henvalt.shopify_privacy_requests where id=v_claim.id;
  if v_payload <> '{}'::jsonb or v_customer is not null then
    raise exception 'terminal privacy request retained inbound PII';
  end if;
end $$;

insert into henvalt.shopify_privacy_requests
  (id,shop_domain,topic,webhook_id,customer_id,payload,status)
values
  ('33333333-3333-4333-8333-333333333333','fixture.myshopify.com',
   'customers/redact','privacy-retry-1','445566',
   '{"customer_email":"retry@example.test"}'::jsonb,'PENDING');

do $$
declare
  v_claim record;
  v_finished boolean;
  v_status text;
  v_payload jsonb;
  v_customer text;
begin
  select * into v_claim from henvalt.claim_shopify_privacy_request_by_id(
    '33333333-3333-4333-8333-333333333333',120
  );
  if v_claim.lease_attempts <> 1 then raise exception 'first retry claim failed'; end if;
  v_finished := henvalt.finish_shopify_privacy_request(
    v_claim.id,v_claim.lease_token,'FAILED','temporary_failure'
  );
  if not v_finished then raise exception 'first failed attempt did not finish'; end if;
  select status,payload,customer_id into v_status,v_payload,v_customer
  from henvalt.shopify_privacy_requests where id=v_claim.id;
  if v_status <> 'FAILED' or v_payload = '{}'::jsonb or v_customer is null then
    raise exception 'retryable failure did not retain minimal retry identifiers';
  end if;

  select * into v_claim from henvalt.claim_shopify_privacy_request_by_id(v_claim.id,120);
  if v_claim.lease_attempts <> 2 then raise exception 'failed request was not reclaimable'; end if;
  v_finished := henvalt.finish_shopify_privacy_request(
    v_claim.id,v_claim.lease_token,'REVIEW_REQUIRED','manual_review'
  );
  if not v_finished then raise exception 'review transition failed'; end if;
  select status,payload,customer_id into v_status,v_payload,v_customer
  from henvalt.shopify_privacy_requests where id=v_claim.id;
  if v_status <> 'REVIEW_REQUIRED' or v_payload <> '{}'::jsonb or v_customer is not null then
    raise exception 'review transition did not clear retained identifiers';
  end if;
end $$;

insert into henvalt.shopify_privacy_requests
  (id,shop_domain,topic,webhook_id,customer_id,payload,status,lease_attempts)
values
  ('44444444-4444-4444-8444-444444444444','fixture.myshopify.com',
   'customers/redact','privacy-retry-limit','778899',
   '{"customer_email":"exhausted@example.test"}'::jsonb,'PENDING',7);

do $$
declare
  v_claim record;
  v_finished boolean;
  v_status text;
  v_payload jsonb;
  v_customer text;
begin
  select * into v_claim from henvalt.claim_shopify_privacy_request_by_id(
    '44444444-4444-4444-8444-444444444444',120
  );
  if v_claim.lease_attempts <> 8 then raise exception 'retry cap fixture not claimed at attempt eight'; end if;
  v_finished := henvalt.finish_shopify_privacy_request(
    v_claim.id,v_claim.lease_token,'FAILED','last_failure'
  );
  if not v_finished then raise exception 'retry cap failure did not finish'; end if;
  select status,payload,customer_id into v_status,v_payload,v_customer
  from henvalt.shopify_privacy_requests where id=v_claim.id;
  if v_status <> 'REVIEW_REQUIRED' or v_payload <> '{}'::jsonb or v_customer is not null then
    raise exception 'retry cap did not force review and clear identifiers';
  end if;
end $$;

rollback;

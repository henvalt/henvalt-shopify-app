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
rollback;

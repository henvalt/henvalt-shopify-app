\set ON_ERROR_STOP on
begin;

do $$
declare
  v_claim record;
  v_result jsonb;
  v_finished boolean;
  v_calls integer;
  v_status text;
  v_payload jsonb;
  v_customer text;
  v_tenant uuid;
  v_lease uuid;
  v_expiry timestamptz;
  v_rejected boolean;
begin
  -- Null legacy lease metadata must never authorize a destructive operation.
  insert into henvalt.shopify_privacy_requests
    (id,tenant_id,shop_domain,shopify_shop_id,topic,webhook_id,customer_id,payload,status)
  values
    ('00000000-0000-4000-8000-000000000001','aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
     'fixture.myshopify.com','1','customers/redact','redaction-null-lease','missing-customer','{}','PROCESSING');
  v_rejected := false;
  begin
    perform henvalt.redact_shopify_customer_data_checked_with_lease(
      '00000000-0000-4000-8000-000000000001',gen_random_uuid()
    );
  exception when others then
    v_rejected := true;
  end;
  if not v_rejected then raise exception 'null legacy lease metadata was accepted'; end if;
  select count(*) into v_calls from henvalt.privacy_redaction_calls;
  if v_calls <> 0 then raise exception 'null legacy lease reached destructive redaction'; end if;

  -- No-match requests must not call the destructive customer-redaction routine.
  insert into henvalt.shopify_privacy_requests
    (id,tenant_id,shop_domain,shopify_shop_id,topic,webhook_id,customer_id,payload,status)
  values
    ('11111111-1111-4111-8111-111111111111','aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
     'fixture.myshopify.com','1','customers/redact','redaction-no-match','missing-customer','{}','PENDING');
  select * into v_claim from henvalt.claim_shopify_privacy_request_by_id(
    '11111111-1111-4111-8111-111111111111',120
  );
  v_result := henvalt.redact_shopify_customer_data_checked_with_lease(v_claim.id,v_claim.lease_token);
  if v_result->>'matched' <> 'false' then raise exception 'no-match redaction falsely reported a match'; end if;
  select count(*) into v_calls from henvalt.privacy_redaction_calls;
  if v_calls <> 0 then raise exception 'no-match request invoked destructive redaction'; end if;
  v_finished := henvalt.finish_shopify_privacy_request(
    v_claim.id,v_claim.lease_token,'REVIEW_REQUIRED','customer_record_not_found'
  );
  if not v_finished then raise exception 'no-match request did not finish under lease'; end if;

  -- Email-linked delivery attempts must not be reported as no-match when the customer row is absent.
  insert into henvalt.delivery_requests(tenant_id,recipient_reference)
  values ('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa','orphan-delivery@example.test');
  insert into henvalt.delivery_attempts(tenant_id,delivery_request_id)
  select 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',id
  from henvalt.delivery_requests
  where tenant_id='aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'
    and recipient_reference='orphan-delivery@example.test';
  insert into henvalt.shopify_privacy_requests
    (id,tenant_id,shop_domain,shopify_shop_id,topic,webhook_id,customer_id,payload,status)
  values
    ('12121212-1212-4212-8212-121212121212','aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
     'fixture.myshopify.com','1','customers/redact','redaction-orphan-delivery',null,
     '{"customer_email":"orphan-delivery@example.test"}','PENDING');
  select * into v_claim from henvalt.claim_shopify_privacy_request_by_id(
    '12121212-1212-4212-8212-121212121212',120
  );
  v_result := henvalt.redact_shopify_customer_data_checked_with_lease(v_claim.id,v_claim.lease_token);
  if v_result->>'matched' <> 'true' then raise exception 'email-linked delivery attempt was missed by redaction preflight'; end if;
  select count(*) into v_calls from henvalt.privacy_redaction_calls;
  if v_calls <> 1 then raise exception 'delivery-attempt match did not dispatch redaction exactly once'; end if;
  v_finished := henvalt.finish_shopify_privacy_request(
    v_claim.id,v_claim.lease_token,'COMPLETED',null
  );
  if not v_finished then raise exception 'orphan delivery request did not finish'; end if;

  -- A matching tenant/customer must call the destructive routine exactly once.
  insert into henvalt.customers(tenant_id,shopify_customer_id,email)
  values ('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa','matched-customer','match@example.test');
  insert into henvalt.shopify_privacy_requests
    (id,tenant_id,shop_domain,shopify_shop_id,topic,webhook_id,customer_id,payload,status)
  values
    ('22222222-2222-4222-8222-222222222222','aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
     'fixture.myshopify.com','1','customers/redact','redaction-match','matched-customer','{}','PENDING');
  select * into v_claim from henvalt.claim_shopify_privacy_request_by_id(
    '22222222-2222-4222-8222-222222222222',120
  );
  v_result := henvalt.redact_shopify_customer_data_checked_with_lease(v_claim.id,v_claim.lease_token);
  if v_result->>'matched' <> 'true' then raise exception 'matching customer was not redacted'; end if;
  select count(*) into v_calls from henvalt.privacy_redaction_calls;
  if v_calls <> 2 then raise exception 'matching customer redaction did not run exactly once'; end if;
  v_finished := henvalt.finish_shopify_privacy_request(
    v_claim.id,v_claim.lease_token,'COMPLETED',null
  );
  if not v_finished then raise exception 'matching customer request did not finish'; end if;

  -- A stale token must be rejected before the destructive function is called.
  insert into henvalt.shopify_privacy_requests
    (id,tenant_id,shop_domain,shopify_shop_id,topic,webhook_id,customer_id,payload,status)
  values
    ('33333333-3333-4333-8333-333333333333','aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
     'fixture.myshopify.com','1','customers/redact','redaction-stale-token','matched-customer','{}','PENDING');
  select * into v_claim from henvalt.claim_shopify_privacy_request_by_id(
    '33333333-3333-4333-8333-333333333333',120
  );
  v_rejected := false;
  begin
    perform henvalt.redact_shopify_customer_data_checked_with_lease(v_claim.id,gen_random_uuid());
  exception when others then
    v_rejected := true;
  end;
  if not v_rejected then raise exception 'stale privacy lease was accepted'; end if;
  select count(*) into v_calls from henvalt.privacy_redaction_calls;
  if v_calls <> 2 then raise exception 'stale lease reached destructive redaction'; end if;

  -- Export generation and persistence occur inside the active lease.
  insert into henvalt.shopify_privacy_requests
    (id,tenant_id,shop_domain,shopify_shop_id,topic,webhook_id,customer_id,payload,status)
  values
    ('44444444-4444-4444-8444-444444444444','aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
     'fixture.myshopify.com','1','customers/data_request','export-found','export-yes',
     '{"customer_email":"export@example.test"}','PENDING');
  select * into v_claim from henvalt.claim_shopify_privacy_request_by_id(
    '44444444-4444-4444-8444-444444444444',120
  );
  v_result := henvalt.export_shopify_customer_data_with_lease(v_claim.id,v_claim.lease_token);
  if v_result->>'found' <> 'true' then raise exception 'export fixture should be found'; end if;
  select result_payload,result_expires_at into v_payload,v_expiry
  from henvalt.shopify_privacy_requests where id=v_claim.id;
  if v_payload is null or v_expiry <= now() then raise exception 'export result was not stored with expiry'; end if;
  v_finished := henvalt.finish_shopify_privacy_request(
    v_claim.id,v_claim.lease_token,'REVIEW_REQUIRED','export_ready_for_secure_merchant_delivery'
  );
  if not v_finished then raise exception 'export request did not finish'; end if;
  select status,payload,customer_id,result_payload into v_status,v_payload,v_customer,v_result
  from henvalt.shopify_privacy_requests where id=v_claim.id;
  if v_status <> 'REVIEW_REQUIRED' or v_payload <> '{}'::jsonb or v_customer is not null or v_result is null then
    raise exception 'export completion did not minimize inbound identifiers while preserving export';
  end if;

  -- A no-match export must clear a stale bundle from an earlier attempt.
  insert into henvalt.shopify_privacy_requests
    (id,tenant_id,shop_domain,shopify_shop_id,topic,webhook_id,customer_id,payload,status,result_payload,result_expires_at)
  values
    ('55555555-5555-4555-8555-555555555555','aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
     'fixture.myshopify.com','1','customers/data_request','export-empty','export-no',
     '{}','PENDING','{"stale":true}'::jsonb,now()+interval '1 day');
  select * into v_claim from henvalt.claim_shopify_privacy_request_by_id(
    '55555555-5555-4555-8555-555555555555',120
  );
  v_result := henvalt.export_shopify_customer_data_with_lease(v_claim.id,v_claim.lease_token);
  if v_result->>'found' <> 'false' then raise exception 'empty export fixture unexpectedly found data'; end if;
  select result_payload into v_payload from henvalt.shopify_privacy_requests where id=v_claim.id;
  if v_payload is not null then raise exception 'stale export bundle was not cleared'; end if;

  -- Shop deletion verifies its lease and clears lease metadata on completion.
  insert into henvalt.shopify_privacy_requests
    (id,tenant_id,shop_domain,shopify_shop_id,topic,webhook_id,payload,status)
  values
    ('66666666-6666-4666-8666-666666666666','aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
     'fixture.myshopify.com','1','shop/redact','shop-redaction','{}','PENDING');
  select * into v_claim from henvalt.claim_shopify_privacy_request_by_id(
    '66666666-6666-4666-8666-666666666666',120
  );
  v_result := henvalt.redact_shopify_shop_data_with_lease(v_claim.id,v_claim.lease_token);
  select status,tenant_id,payload,lease_token into v_status,v_tenant,v_payload,v_lease
  from henvalt.shopify_privacy_requests where id=v_claim.id;
  if v_status <> 'COMPLETED' or v_tenant is not null or v_payload <> '{}'::jsonb or v_lease is not null then
    raise exception 'shop redaction did not complete and clear its lease';
  end if;
end $$;

rollback;

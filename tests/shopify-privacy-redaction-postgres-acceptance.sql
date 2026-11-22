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
begin
  -- A no-match request must not call the destructive redaction routine.
  insert into henvalt.shopify_privacy_requests
    (id,tenant_id,shop_domain,shopify_shop_id,topic,webhook_id,customer_id,payload,status)
  values
    ('11111111-1111-4111-8111-111111111111','aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
     'fixture.myshopify.com','1','customers/redact','redaction-no-match','missing-customer','{}','PENDING');
  select * into v_claim from henvalt.claim_shopify_privacy_request_by_id(v_claim.id,120);
end $$;
rollback;

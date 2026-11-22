drop schema if exists henvalt cascade;
create schema henvalt;
do $$ begin
  create role service_role nologin;
exception when duplicate_object then null;
end $$;
do $$ begin
  create role anon nologin;
exception when duplicate_object then null;
end $$;
do $$ begin
  create role authenticated nologin;
exception when duplicate_object then null;
end $$;
create table henvalt.shopify_privacy_requests (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid,
  shop_domain text not null,
  shopify_shop_id text,
  topic text not null,
  webhook_id text not null unique,
  customer_id text,
  request_id text,
  payload jsonb not null,
  status text not null default 'PENDING',
  received_at timestamptz not null default now(),
  processed_at timestamptz,
  last_error text,
  result_payload jsonb,
  result_expires_at timestamptz,
  result_delivered_at timestamptz,
  constraint shopify_privacy_requests_status_check
    check (status in ('PENDING','PROCESSING','COMPLETED','FAILED','REVIEW_REQUIRED'))
);

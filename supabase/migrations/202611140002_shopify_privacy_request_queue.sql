-- Durable receipt queue for Shopify mandatory privacy compliance requests.
-- Requests remain pending until the dedicated processor completes export/redaction.
create table if not exists henvalt.shopify_privacy_requests (
  id uuid primary key default gen_random_uuid(),
  -- Nullable so Shopify redaction requests remain auditable after a tenant is removed.\n  tenant_id uuid references henvalt.tenants(id) on delete set null,
  shop_domain text not null,
  shopify_shop_id text,
  topic text not null check (topic in ('customers/data_request','customers/redact','shop/redact')),
  webhook_id text not null,
  customer_id text,
  request_id text,
  payload jsonb not null,
  status text not null default 'PENDING'
    check (status in ('PENDING','PROCESSING','COMPLETED','FAILED','REVIEW_REQUIRED')),
  received_at timestamptz not null default now(),
  processed_at timestamptz,
  last_error text,
  constraint shopify_privacy_requests_webhook_unique unique (webhook_id)
);

create index if not exists shopify_privacy_requests_shop_status_idx\n  on henvalt.shopify_privacy_requests (shop_domain, status, received_at);\n\ncreate index if not exists shopify_privacy_requests_pending_idx
  on henvalt.shopify_privacy_requests (status, received_at)
  where status in ('PENDING','FAILED','REVIEW_REQUIRED');

alter table henvalt.shopify_privacy_requests enable row level security;
revoke all on henvalt.shopify_privacy_requests from public, anon, authenticated;
grant select, insert, update on henvalt.shopify_privacy_requests to service_role;

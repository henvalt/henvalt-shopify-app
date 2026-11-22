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

-- Minimal tenant-scoped stores required by the candidate customer-redaction preflight.
create table henvalt.customers (tenant_id uuid, shopify_customer_id text, email text);
create table henvalt.checkouts (tenant_id uuid, email text);
create table henvalt.canonical_events (tenant_id uuid, customer_reference text, email text, payload jsonb default '{}'::jsonb);
create table henvalt.delivery_requests (tenant_id uuid, recipient_reference text);
create table henvalt.messages (tenant_id uuid, recipient text);
create table henvalt.conversation_messages (tenant_id uuid, sender_email text, recipient_email text);
create table henvalt.email_suppressions (tenant_id uuid, email_normalized text);
create table henvalt.provider_events (tenant_id uuid, recipient_email text);
create table henvalt.recovery_interventions (tenant_id uuid, recipient_reference text);
create table henvalt.webhook_events (tenant_id uuid, payload jsonb default '{}'::jsonb);
create table henvalt.processing_errors (tenant_id uuid, payload jsonb default '{}'::jsonb);
create table henvalt.background_jobs (tenant_id uuid, payload jsonb default '{}'::jsonb);
create table henvalt.audit_log (tenant_id uuid, payload jsonb default '{}'::jsonb);
create table henvalt.privacy_redaction_calls (id bigint generated always as identity primary key);

create or replace function henvalt.redact_shopify_customer_data(
  p_tenant_id uuid, p_shopify_customer_id text, p_customer_email text default null
) returns jsonb language plpgsql security definer set search_path=henvalt,pg_temp as $$
begin
  insert into henvalt.privacy_redaction_calls default values;
  return jsonb_build_object('matched',true,'stubbed',true);
end $$;

create or replace function henvalt.export_shopify_customer_data(
  p_tenant_id uuid, p_shopify_customer_id text, p_customer_email text default null
) returns jsonb language sql security definer set search_path=henvalt,pg_temp as $$
  select jsonb_build_object(
    'found', p_shopify_customer_id = 'export-yes',
    'fixture', true
  );
$$;

create or replace function henvalt.redact_shopify_shop_data(
  p_privacy_request_id uuid
) returns jsonb language plpgsql security definer set search_path=henvalt,pg_temp as $$
begin
  update henvalt.shopify_privacy_requests
  set tenant_id=null, customer_id=null, payload='{}'::jsonb,
      status='COMPLETED', processed_at=now(), last_error=null
  where id=p_privacy_request_id;
  return jsonb_build_object('completed',true,'stubbed',true);
end $$;


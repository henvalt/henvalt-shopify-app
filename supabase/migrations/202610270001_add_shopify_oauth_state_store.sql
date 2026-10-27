-- Additive OAuth state storage; does not alter existing tenant or recovery data.
create table if not exists henvalt.shopify_oauth_states (
  state_hash text primary key,
  shop_domain text not null check (shop_domain ~ '^[a-z0-9][a-z0-9-]*\\.myshopify\\.com$'),
  created_at timestamptz not null default now(),
  expires_at timestamptz not null,
  consumed_at timestamptz,
  correlation_id uuid not null default gen_random_uuid(),
  constraint shopify_oauth_state_expiry_check check (expires_at > created_at)
);
create index if not exists shopify_oauth_states_expires_at_idx on henvalt.shopify_oauth_states (expires_at);
alter table henvalt.shopify_oauth_states enable row level security;
revoke all on table henvalt.shopify_oauth_states from anon, authenticated;
grant all on table henvalt.shopify_oauth_states to service_role;
comment on table henvalt.shopify_oauth_states is 'Short-lived one-time Shopify OAuth state records; stores SHA-256 hashes only.';

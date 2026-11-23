-- OAuth initiation binds the one-time state to the authenticated merchant.
-- Nullable preserves compatibility with short-lived records created before this migration;
-- the callback and finalization RPC already reject states without an owner.
alter table henvalt.shopify_oauth_states
  add column if not exists initiated_by_user_id uuid references auth.users(id) on delete cascade;

create index if not exists shopify_oauth_states_initiated_by_user_id_idx
  on henvalt.shopify_oauth_states (initiated_by_user_id)
  where initiated_by_user_id is not null;

comment on column henvalt.shopify_oauth_states.initiated_by_user_id is
  'Authenticated Supabase user who initiated the OAuth flow; required by the owner-bound finalization RPC.';

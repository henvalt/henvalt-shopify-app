-- HENVALT app-aware identity: source-lineage migration preflight
-- STATUS: REVIEW-ONLY / READ-ONLY. DO NOT APPLY AS A MIGRATION.
-- Target: henvalt Supabase project ocyplckdojdubyrsxcxa
-- Purpose: collect safe aggregate/catalog evidence before designing executable DDL.
-- This file contains SELECT statements only. It does not backfill, lock, or mutate data.

-- 1) Confirm the anchor columns and nullable state of the current live schema.
select
  table_name,
  column_name,
  data_type,
  is_nullable,
  column_default
from information_schema.columns
where table_schema = 'henvalt'
  and table_name in (
    'shopify_connections',
    'shopify_oauth_states',
    'webhook_events',
    'canonical_events',
    'pixel_keys'
  )
order by table_name, ordinal_position;

-- 2) Confirm existing unique keys and conflict-target-sensitive indexes.
-- Do not change idempotency constraints until every writer's ON CONFLICT target is reviewed.
select
  t.relname as table_name,
  i.relname as index_name,
  ix.indisunique,
  ix.indisprimary,
  pg_get_indexdef(ix.indexrelid) as index_definition
from pg_class t
join pg_namespace n on n.oid = t.relnamespace
join pg_index ix on ix.indrelid = t.oid
join pg_class i on i.oid = ix.indexrelid
where n.nspname = 'henvalt'
  and t.relname in (
    'shopify_connections',
    'shopify_oauth_states',
    'webhook_events',
    'canonical_events'
  )
order by t.relname, i.relname;

-- 3) Verify the composite-FK target prerequisite.
-- Expected today: the UUID PK exists, but a unique (tenant_id,id) target may not.
select
  conrelid::regclass as table_name,
  conname,
  pg_get_constraintdef(oid) as constraint_definition
from pg_constraint
where connamespace = 'henvalt'::regnamespace
  and conrelid = 'henvalt.shopify_connections'::regclass
order by conname;

-- 4) Aggregate source-row lineage gaps.
-- These counts intentionally reveal no shop domains, tenant IDs, customer data, or tokens.
select
  'webhook_events' as table_name,
  count(*) as total_rows,
  null::bigint as rows_with_connection_id,
  count(*) as rows_without_connection_id
from henvalt.webhook_events
union all
select
  'canonical_events',
  count(*),
  null::bigint,
  count(*)
from henvalt.canonical_events
union all
select
  'pixel_keys',
  count(*),
  count(shopify_connection_id),
  count(*) filter (where shopify_connection_id is null)
from henvalt.pixel_keys;

-- 5) Connection and OAuth-state aggregate status.
-- Counts only; no raw shop domains or state hashes are returned.
select
  count(*) as connection_rows,
  count(*) filter (where active) as active_connections,
  count(*) filter (where not active) as inactive_connections,
  count(*) filter (where access_token_secret_ref is not null) as rows_with_access_token_reference,
  count(*) filter (where refresh_token_secret_ref is not null) as rows_with_refresh_token_reference
from henvalt.shopify_connections;

select
  count(*) as oauth_state_rows,
  count(*) filter (where consumed_at is null and expires_at > now()) as unconsumed_unexpired_states,
  count(*) filter (where consumed_at is not null) as consumed_states,
  count(*) filter (where expires_at <= now()) as expired_states
from henvalt.shopify_oauth_states;

-- 6) Detect duplicate normalized shop domains without disclosing the values.
-- A non-zero result must be resolved before any normalized-domain resolver is enabled.
select count(*) as duplicate_normalized_domain_groups
from (
  select lower(btrim(shop_domain)) as normalized_domain
  from henvalt.shopify_connections
  group by lower(btrim(shop_domain))
  having count(*) > 1
) duplicates;

-- 7) Check whether app registry / app identity columns already exist.
-- This is an inventory query, not a request to create them.
select
  to_regclass('henvalt.shopify_app_registry') as app_registry_table,
  exists (
    select 1 from information_schema.columns
    where table_schema = 'henvalt'
      and table_name = 'shopify_connections'
      and column_name = 'app_key'
  ) as connections_app_key_exists,
  exists (
    select 1 from information_schema.columns
    where table_schema = 'henvalt'
      and table_name = 'shopify_oauth_states'
      and column_name = 'app_key'
  ) as oauth_states_app_key_exists,
  exists (
    select 1 from information_schema.columns
    where table_schema = 'henvalt'
      and table_name = 'webhook_events'
      and column_name = 'shopify_connection_id'
  ) as webhook_connection_id_exists,
  exists (
    select 1 from information_schema.columns
    where table_schema = 'henvalt'
      and table_name = 'canonical_events'
      and column_name = 'shopify_connection_id'
  ) as canonical_connection_id_exists;

-- 8) Inspect RLS flags for the identity anchor/source tables.
select
  c.relname as table_name,
  c.relrowsecurity as rls_enabled,
  c.relforcerowsecurity as rls_forced
from pg_class c
join pg_namespace n on n.oid = c.relnamespace
where n.nspname = 'henvalt'
  and c.relname in (
    'shopify_connections',
    'shopify_oauth_states',
    'webhook_events',
    'canonical_events',
    'pixel_keys'
  )
order by c.relname;

-- 9) Inspect policies without exposing policy row data.
select
  tablename,
  policyname,
  permissive,
  roles,
  cmd
from pg_policies
where schemaname = 'henvalt'
  and tablename in (
    'shopify_connections',
    'shopify_oauth_states',
    'webhook_events',
    'canonical_events',
    'pixel_keys'
  )
order by tablename, policyname;

-- 10) Inventory writer function signatures that must gain app/connection-aware successors.
-- Do not replace legacy functions in place during the additive rollout.
select
  p.proname as function_name,
  pg_get_function_identity_arguments(p.oid) as identity_arguments,
  pg_get_function_result(p.oid) as result_type,
  p.prosecdef as security_definer
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'henvalt'
  and p.proname in (
    'control_plane_connect_shop',
    'control_plane_finalize_shopify_oauth_install_expiring_for_owner',
    'verify_shopify_webhook_hmac',
    'resolve_shopify_tenant',
    'upsert_customer',
    'upsert_checkout',
    'upsert_canonical_event',
    'project_order_from_event'
  )
order by p.proname, identity_arguments;

-- 11) Explicitly verify the source-event FK shape.
-- Canonical events must inherit connection identity from the exact webhook receipt;
-- this existing FK is inspected, not modified.
select
  conrelid::regclass as table_name,
  conname,
  pg_get_constraintdef(oid) as constraint_definition
from pg_constraint
where connamespace = 'henvalt'::regnamespace
  and conrelid in (
    'henvalt.canonical_events'::regclass,
    'henvalt.webhook_events'::regclass,
    'henvalt.pixel_keys'::regclass
  )
order by table_name::text, conname;

-- 12) Migration readiness is NOT established by this preflight alone.
-- Required before executable DDL:
--   * exact immutable provenance for each legacy app/connection row;
--   * all writer ON CONFLICT clauses reconciled with the indexes above;
--   * RLS, grants, default privileges, function owners and callers reviewed;
--   * isolated two-store fixtures pass source-to-recovery lineage tests;
--   * store-scoped privacy deletion and billing principal decisions completed.

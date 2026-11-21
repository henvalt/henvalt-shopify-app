# Live Supabase RLS, grants and security-advisor review (2026-11-16)

Status: read-only catalog inspection and Supabase security-advisor retrieval. No policies, grants, functions, tables, views, default privileges or Auth settings were changed.

## Results

### Table RLS and direct grants

- Every base table returned in the `henvalt` schema has row-level security enabled.
- The inspected `henvalt` tables do not have `FORCE ROW LEVEL SECURITY`; service-role callers therefore continue to bypass RLS as expected for the service role.
- The `information_schema.role_table_grants` query for `anon`, `authenticated` and `service_role` returned only service_role grants for the inspected `henvalt` tables. No direct table grants to anon or authenticated were present in that result.
- The `henvalt` schema has USAGE for authenticated and service_role, but not anon. None of those roles has CREATE on `henvalt`.
- The `vault` schema has USAGE only for service_role among the inspected API roles; anon/authenticated have neither USAGE nor CREATE.
- The public schema grants USAGE but not CREATE to anon/authenticated/service_role.
- The catalog view query returned no views in `henvalt` or `public` at the time of inspection.

This supports the current design in which direct table access is service-side and user-facing access is routed through explicitly granted RPCs/Edge Functions. It does not prove every RPC/Edge Function is safe: service-role callers bypass RLS, so their authentication and SQL/function authorization contracts remain critical.

### Tables with RLS enabled but no policies

Supabase's security advisor returned 11 INFO findings for tables with RLS enabled but no policies:
- `billing_accounts`
- `billing_usage_charges`
- `communication_jurisdiction_policies`
- `country_code_registry`
- `email_usage_measurements`
- `pixel_collector_auth`
- `pixel_keys`
- `pixel_rate_limits`
- `session_aliases`
- `shopify_oauth_states`
- `shopify_privacy_requests`

These tables had service_role-only direct grants in the inspected grant output, or no user-facing direct grants. The absence of policies is therefore consistent with a service-only table model; it is not automatically a defect. Keep the no-direct-client-grant property as a release invariant. If direct authenticated access is ever introduced, design and test a tenant/connection policy first.

### `is_tenant_member(uuid)` SECURITY DEFINER warning

Supabase's security advisor returned one WARN:
- `henvalt.is_tenant_member(p_tenant_id uuid)` is executable by `authenticated` and is `SECURITY DEFINER`.

Read-only function inspection confirmed:
- The function is SQL, STABLE and SECURITY DEFINER.
- It pins `search_path` to `henvalt, pg_temp`.
- Its only query is an EXISTS lookup in `henvalt.tenant_memberships` requiring both `tm.tenant_id = p_tenant_id` and `tm.user_id = auth.uid()`.
- Its ACL is postgres, authenticated and service_role; anon is not granted EXECUTE.
- The helper is referenced by the tenant-isolation policies on the tenant-scoped tables and by tenant-membership insert/update policies.

Assessment: the advisor warning is real, but the inspected body contains the expected caller binding through `auth.uid()`, uses a pinned search path, and only returns a boolean membership result. It appears intentionally exposed as the helper used by RLS. Do not blindly revoke it or convert it to SECURITY INVOKER without first replacing the RLS helper design and testing all policies. Keep it on the review list and add explicit tests that a user cannot test membership by impersonating another UID or use this function to read tenant data.

### Auth leaked-password protection

The security advisor also reports leaked-password protection disabled. This is an Auth hardening recommendation, not an identity-lineage defect. It should be reviewed in Supabase Auth settings before a commercial launch; no Auth setting was changed during this audit.

### Default privileges

The catalog returned default ACL entries in the `public` schema that include anon/authenticated grants for some future object types, while the `henvalt` schema's inspected default function ACL is service_role-only. These entries may be inherited from Supabase's project defaults and may be owner-specific. This pass did not change them and did not establish the effective defaults for every possible object owner. Before adding objects to exposed schemas, explicitly inspect owner-specific default privileges and ensure new exposed tables have RLS and least-privilege grants.

## Release invariants

1. Keep `henvalt` tables unavailable for direct anon/authenticated table access unless an explicit reviewed client access design is approved.
2. Keep all tenant-scoped RLS policies bound to the authenticated user's server-verified `auth.uid()`; never use user-editable JWT metadata for authorization.
3. Keep service-role credentials server-only and inventory every Edge Function, n8n credential and Worker binding that can use them.
4. Do not treat SECURITY DEFINER warnings as automatically exploitable or automatically safe; review body, ACL, search_path, caller binding and policy dependencies together.
5. Review leaked-password protection in Auth settings before commercial launch.
6. Recheck RLS, grants, policies, views and default privileges after the additive multi-store identity migration.

## Evidence and limits

Evidence:
- Read-only PostgreSQL catalog queries for table RLS, policy expressions, schema privileges, table grants, views and default ACL.
- Supabase security advisor output observed 2026-11-16.
- Exact deployed definition and ACL of `henvalt.is_tenant_member(uuid)`.

Not established:
- Every non-security-definer function overload or every RPC's full authorization semantics.
- Every owner-specific default privilege for future objects.
- Secret values, access history, or compromise status.
- Any change to production permissions or Auth settings.

No production changes were made. This audit is review-only.

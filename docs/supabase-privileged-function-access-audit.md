# Supabase Privileged Function Access Audit

Status: read-only catalog inspection of the live `henvalt` schema. No grants, policies, functions or database objects were changed.

## Scope

Inspected deployed function metadata through PostgreSQL catalogs:
- `SECURITY DEFINER` functions in schema `henvalt`;
- effective EXECUTE privileges for `anon`, `authenticated` and `service_role`;
- configured function `search_path`;
- CREATE/USAGE privileges on `public`, `henvalt` and `vault`.

## Findings

### Positive: privileged function execution is not broadly granted

The inspected `SECURITY DEFINER` functions in `henvalt` have explicit ACLs granting EXECUTE to `postgres` and `service_role`, not `anon` or `authenticated`. The exception is `is_tenant_member(uuid)`, which is also executable by `authenticated` and is the expected membership helper.

Effective privilege checks confirmed:
- `anon`: no EXECUTE on the inspected SECURITY DEFINER functions;
- `authenticated`: no EXECUTE except `is_tenant_member`;
- `service_role`: EXECUTE on the inspected SECURITY DEFINER functions.

This is a positive baseline. Preserve the service-only boundary for internal ingestion, recovery, delivery, billing, privacy and secret-access routines. Any future browser-facing API should use a narrowly scoped authenticated wrapper that validates membership and store selection, not direct grants to internal functions.

### Positive: untrusted roles cannot CREATE objects in searched schemas

Catalog privilege checks returned no CREATE privilege for `anon`, `authenticated` or `service_role` on `public`, `henvalt` and `vault`. The `henvalt` schema is not USAGE-accessible to `anon`; `authenticated` has USAGE but no CREATE. `vault` is limited to service-role usage in the checked role set.

Several SECURITY DEFINER routines include `public` in their configured search path. The checked roles cannot create objects in `public`, which reduces the immediate object-shadowing risk from these roles. Continue to prefer schema-qualified references and a minimal search path for new privileged routines.

### Remaining verification

This was a catalog-level check of function ACLs and schema privileges, not a complete audit of:
- all non-SECURITY DEFINER functions and overloaded signatures;
- table/view grants and RLS policy expressions;
- default privileges for future functions;
- external service-role key custody and Edge Function authorization;
- whether every exposed Edge Function authenticates its caller before invoking service-role RPCs.

The positive ACL result does not prove that a leaked service-role key is safe. Service-role credentials must remain server-side and protected.

## Release requirements

1. Keep internal SECURITY DEFINER functions service-role-only unless a documented exception is required.
2. Keep `is_tenant_member` as a minimal membership predicate; never treat it as proof that a selected store belongs to a user unless the calling policy also checks the connection's tenant.
3. Add CI/catalog assertions for anon/authenticated EXECUTE on sensitive function families and for schema CREATE grants.
4. Audit Edge Function caller authentication and service-role secret handling before public distribution.
5. Re-run privilege checks after migrations because default privileges and function overloads can change independently.

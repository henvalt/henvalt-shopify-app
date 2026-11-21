# Supabase advisor review — 2026-11-21

**Scope:** Read-only production advisor and catalog review. The only code change associated with this review is an additive candidate index migration on the isolated PR branch. No production SQL, settings, policies, grants, or data were changed.

## Findings and disposition

### RLS enabled with no policies — 11 backend tables

The advisor reports 11 tables in the `henvalt` schema with RLS enabled and no policies:

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

Catalog inspection confirmed that all 11 have RLS enabled and zero policies. It also confirmed no direct `SELECT` or `INSERT` grants to `anon` or `authenticated` on these tables. `service_role` has backend access to the tables except `pixel_collector_auth`, which is deliberately more restricted.

**Disposition:** This is intentionally backend-only and fail-closed, not a reason to add broad policies. Do not add client policies merely to silence the advisor. Revisit only if a supported client workflow is explicitly designed for one of these tables.

### SECURITY DEFINER membership helper

The advisor flags `henvalt.is_tenant_member(uuid)` because `authenticated` can execute it. Catalog inspection shows it is a stable SQL SECURITY DEFINER function that returns only whether the caller's `auth.uid()` has a membership row for the supplied tenant ID. Its table and auth references are schema-qualified. The `authenticated` role has no `CREATE` privilege on `henvalt`; neither does `anon`. The helper is used by tenant-scoped authorization and must remain callable by authenticated users for those policies.

**Disposition:** Retain the intentional boolean membership helper; do not revoke its execute grant without first redesigning dependent RLS policies. Keep its implementation limited to the caller's own `auth.uid()`, never return membership rows or tenant data. The advisor warning is documented, not silently ignored.

### Leaked-password protection disabled

Supabase Auth reports leaked-password protection disabled.

**Disposition:** This is an Auth project setting, not a SQL migration. It requires an owner-level settings change and should be enabled before public onboarding where the current plan supports it. No setting was changed during this pass.

### Missing foreign-key index

The performance advisor identifies `shopify_privacy_requests.tenant_id` as a foreign key without a covering index. The existing indexes cover shop/status/time, pending status/time, export expiry and primary/unique keys, but none starts with `tenant_id`.

**Disposition:** Added candidate migration `202611210012_shopify_privacy_tenant_fk_index.sql` to create a normal B-tree index on `tenant_id`, plus disposable PostgreSQL bootstrap/acceptance checks. This migration is not applied to production.

### Unused indexes

The advisor reports 71 unused indexes. Current traffic is sparse and the recovery scheduler is often idle, so usage statistics are not enough evidence to drop them. Several indexes protect tenant joins, idempotency, queue claims, and future workload paths.

**Disposition:** No index removals. Reassess only after representative production workload and query-plan evidence.

### Health advisor

The Supabase health advisor returned no findings in this snapshot.

## Verification boundary

- Production project remained read-only.
- The 11 no-policy tables remain inaccessible directly to `anon` and `authenticated` by grants as well as RLS.
- No policy, grant, Auth setting, or production index was changed.
- Candidate migration 012 must pass disposable PostgreSQL CI and then full-schema isolated Supabase staging before any production review.

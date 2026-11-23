# Dashboard Edge Function v4 source reconciliation

**Status:** v4 baseline reconciled and input validation hardened in Git; not deployed
**Live project:** `ocyplckdojdubyrsxcxa`
**Function:** `henvalt-merchant-dashboard`
**Deployed version inspected:** 4
**Deployed baseline source SHA-256:** `2cb76c18f7914ef75add999fd94d27f123fffbca1dc51394941e0708a072b44e`
**Repository commit:** `2bbc7ed94217acfbdf3ab858124880d2cfe87565`

## What changed

The repository file `supabase/functions/henvalt-merchant-dashboard/index.ts` was first reconciled to the `index.ts` content returned by Supabase for deployed version 4. This branch then adds a local pure validator (`validation.ts`) and imports it from the handler; the current branch is therefore a deliberate hardened derivative, not a byte-for-byte copy of the deployed function.

The previous branch copy was missing:
- `control_plane_revenue_series` invocation and granularity handling;
- confirmed recovery ledger query and joined order / attribution / legacy billing measurement fields;
- `revenueSeries` and `revenueComparison` response properties;
- the deployed source's date-range and granularity contract.

The reconciled source retains the existing Auth user validation, exactly-one-membership check, exactly-one-active-shop check, server-side service-role access, tenant-scoped ledger query, no-store response and error boundary.

## Explicit non-changes

- No Supabase deployment was performed.
- No production SQL, migration or RLS policy was changed.
- No secrets, keys or credentials were added to Git.
- No dashboard UI or billing semantics were changed.
- No n8n workflow, Shopify app version, recovery toggle, sender or provider setting was changed.

## Verification still required before deployment

1. Compare the deployed function's version/hash against this committed source using the Supabase function export or deployment pipeline.
2. Run Deno type-check plus isolated handler tests for Auth validation, zero / multiple tenant memberships, zero / multiple active shops, fail-closed configuration, request methods, and tenant-scoped confirmed-ledger filters.
   - Explicit malformed dates now return HTTP 400 rather than silently falling back to defaults.
   - Impossible calendar dates (for example, February 31), reversed ranges, ranges longer than 366 days, and unsupported granularities are rejected by a shared pure validator.
   - Automated tests cover leap days, malformed dates, defaults, reversed / overlong ranges, and all supported / unsupported granularities (8 tests).
   - Handler tests inject a deterministic fetch implementation; they verify Auth is checked first, privileged lookups use server credentials, ambiguous memberships / shops fail closed, and the ledger filter includes tenant, recovery entry type and confirmed attribution.
   - A regression assertion verifies the standard `Authorization: Bearer <token>` header is normalized to exactly one bearer prefix before the Auth request.
   - These are mocked integration-contract tests, not proof of live Supabase Auth, PostgREST relationship, RLS or RPC behavior. Latest verified GitHub Actions run: 19 tests passed, 0 failed; the Deno type-check also passed.
3. Run the isolated handler tests in CI; then exercise the same paths against a controlled Supabase test tenant before production deployment.
4. Verify the revenue series and ledger responses remain tenant scoped and confirmed-attribution only.
5. Review the wildcard CORS origin against the production dashboard's actual origin and the intended app embedding model.
6. Deploy only through a reviewed release workflow after all tests pass, then verify the deployed version and response contract.

## Security review note

The live function uses the service-role key only inside the Edge Function and validates the caller token against Supabase Auth before resolving tenant scope. Keep those boundaries intact. The endpoint currently allows `access-control-allow-origin: *`; bearer-token validation is still required and must not be replaced by CORS as an authorization control. Confirm the intended browser origins before tightening or changing CORS.

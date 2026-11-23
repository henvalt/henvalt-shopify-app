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
- Dashboard chart now consumes the API's `revenueSeries` buckets instead of reconstructing a trend from only the latest eight activity rows; no billing semantics were changed.
- No n8n workflow, Shopify app version, recovery toggle, sender or provider setting was changed.

## Verification still required before deployment

1. Compare the deployed function's version/hash against this committed source using the Supabase function export or deployment pipeline.
2. Run Deno type-check plus isolated handler tests for Auth validation, zero / multiple tenant memberships, zero / multiple active shops, fail-closed configuration, request methods, and tenant-scoped confirmed-ledger filters.
   - Explicit malformed dates now return HTTP 400 rather than silently falling back to defaults.
   - Impossible calendar dates (for example, February 31), reversed ranges, ranges longer than 366 days, and unsupported granularities are rejected by a shared pure validator.
   - Automated tests cover leap days, malformed dates, defaults, reversed / overlong ranges, and all supported / unsupported granularities (8 tests).
   - Handler tests inject a deterministic fetch implementation; they verify Auth is checked first, privileged lookups use server credentials, ambiguous memberships / shops fail closed, and the ledger filter includes tenant, recovery entry type and confirmed attribution.
   - A regression assertion verifies the standard `Authorization: Bearer <token>` header is normalized to exactly one bearer prefix before the Auth request.
   - The mocked revenue-series fixture now matches the live RPC's actual `{ bucket, recovered_revenue }` shape, and the handler test asserts the recovered amount field.
   - These are mocked integration-contract tests, not proof of live Supabase Auth, PostgREST relationship, RLS or RPC behavior. Latest verified GitHub Actions run: 19 tests passed, 0 failed; the Deno type-check also passed.
3. Run the isolated handler tests in CI; then exercise the same paths against a controlled Supabase test tenant before production deployment.
4. Verify the revenue series and ledger responses remain tenant scoped and confirmed-attribution only.
5. Review the wildcard CORS origin against the production dashboard's actual origin and the intended app embedding model.
6. Deploy only through a reviewed release workflow after all tests pass, then verify the deployed version and response contract.

## Security review note

The live function uses the service-role key only inside the Edge Function and validates the caller token against Supabase Auth before resolving tenant scope. Keep those boundaries intact. The endpoint currently allows `access-control-allow-origin: *`; bearer-token validation is still required and must not be replaced by CORS as an authorization control. Confirm the intended browser origins before tightening or changing CORS.


## Live test-tenant verification — 2026-11-23

Read-only verification was performed against the connected test tenant after the candidate CI run:

- Tenant is ACTIVE and has exactly one membership and one active Shopify connection (ur4jvw-nz.myshopify.com), satisfying the candidate handler's unambiguous tenant/shop selection assumptions.
- The tenant currently has zero revenue-ledger rows, including zero confirmed recovery rows. The dashboard must therefore show zero verified recovered revenue; it must not synthesize revenue from opportunity or delivery activity.
- The tenant has 165 canonical events, 4 opportunities, 4 recovery interventions and 3 delivery requests. The latest canonical event is 2026-11-14 17:44:35 UTC; the latest opportunity is 2026-11-13 07:06:34 UTC. These are historical test records, not evidence of a current live Shopify event path.
- All four recovery flow toggles and the tenant-wide recovery switch remain disabled.
- The billing account remains PENDING in test mode, with no active Shopify subscription or usage line item. Four email-usage measurements exist and all four are unpriced. No production billing or delivery entitlement was granted.
- The scheduled recovery worker's latest inspected run completed successfully, but its three discovery procedures each returned zero newly queued/created opportunities; stale-work repair and deferred-payment reconciliation returned zero work.
- No recent ingest or delivery executions were returned by the execution search. This does not prove webhook registration is broken, but it means there is no fresh end-to-end event-to-delivery evidence.

### Deployment gate

The authenticated dashboard endpoint has not yet been exercised against live Supabase Auth, PostgREST relationships and RPCs. A valid owner/merchant session is required for that check; no credential was available to this audit, and no credential was requested or stored. The tenant's merchant legal sender profile is also incomplete, so recovery must remain disabled. These are operational blockers, not reasons to weaken authentication, consent, billing or sender checks.

The Supabase security advisor also reports the existing henvalt.is_tenant_member(uuid) SECURITY DEFINER function as executable by authenticated. It checks auth.uid() against tenant membership and is referenced by existing RLS policies; no privilege change was made because revoking it without a dependency migration could break those policies. Review the intended RPC exposure and policy dependencies separately before changing grants.


## Confirmed-revenue activity correction — 2026-11-23

A further code review found that the deployed summary RPC labels an opportunity as recovered using its opportunity status and exposes `value_at_risk` as the activity amount. That value is an estimate, not the paid order's recovered amount. The dashboard candidate now:

- Selects `opportunity_id` from the revenue ledger and filters ledger rows to `entry_type=RECOVERY`, `attribution_confidence=CONFIRMED`, and `billable=true`.
- Replaces an activity row's displayed amount only when a matching confirmed, billable ledger entry exists for that opportunity.
- Sets the activity amount to null when there is no matching ledger entry, so the UI displays no monetary amount instead of presenting estimated value at risk as recovered revenue.
- Adds regression coverage for a matched ledger entry, an unmatched recovered opportunity, a pending opportunity, and the PostgREST query filters.

Latest verified candidate commit: `9612a7d85b698678a19e46ab8e9640e6df229b36`. GitHub Actions run `45121661863` passed Deno type-check and all 19 tests (8 range tests + 11 handler tests).

## Shopify webhook integrity evidence

The n8n ingest workflow's Webhook node has `rawBody=true`; the n8n Webhook implementation places the exact raw request bytes in the binary `data` property while retaining parsed JSON in `body`. The workflow passes the base64 binary bytes and `X-Shopify-Hmac-Sha256` header to the private `verify_shopify_webhook_hmac` RPC before tenant resolution and event ingestion. Read-only tenant records show 130 webhook events reached the ingest ledger after that verification step: 129 processed and one failed business validation. This is evidence that historical webhook HMAC verification and ingestion worked; it is not evidence of a current webhook delivery today.

The one failed webhook was a `checkouts/update` event from 2026-11-02. Its recorded processing error was `missing_checkout_data`: checkout ID and customer email were not both available to create a recovery opportunity. It was not an HMAC failure. The latest Shopify webhook event was received 2026-11-14 15:44:42 UTC; the latest pixel event was received 2026-11-14 17:44:38 UTC. The pipeline has no fresh event evidence after those timestamps.

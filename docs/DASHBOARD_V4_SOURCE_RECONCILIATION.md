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

Latest verified candidate commit: `9612a7d85b698678a19e46ab8e9640e6df229b36`. GitHub Actions run `45121661863` passed Deno type-check and all 19 tests (8 range tests + 11 handler tests). The current documentation/audit head `49bace1b7a7e323996d7565a42f46c7e561e42f9` also passed GitHub Actions run `1902` (Shopify app configuration/static validation) and dashboard Edge Function run `27` (Deno type-check and both validation/handler test files).


## Additional live RPC semantics audit — 2026-11-23

A read-only inspection of the deployed `control_plane_dashboard_summary` and `control_plane_revenue_series` function definitions found two further metric-integrity issues that are not changed by this PR:

1. **Recovered count semantics differ by dashboard section.** The headline `metrics.recoveredOrders` counts distinct `order_attributions.order_id` rows with `attribution_confidence='CONFIRMED'`. The `byEvent[].recovered` breakdown instead counts `opportunities.status='RECOVERED'`. Those are different predicates and can disagree. The attribution table has a unique `(tenant_id, order_id)` constraint and an `opportunity_id` FK, so the per-event breakdown can be reconciled against confirmed attributions joined to their opportunity type. The current test tenant has no attribution or revenue rows, so no live mismatch was observed; this is a code-path discrepancy, not an observed incorrect figure.
2. **Revenue aggregation assumes one currency without enforcing it.** Both summary and revenue-series RPCs sum all confirmed, billable ledger amounts without grouping or filtering by currency. The summary then selects one currency from the latest opportunity/ledger row (or tenant default) and formats the combined amount as that currency. If a store has confirmed billable recoveries in multiple currencies, the displayed total and chart would add unlike units. The inspected test tenant currently has zero confirmed billable recovery rows and a null default currency, so the risk is unexercised, not observed.

The summary RPC's `recoveryRate` also divides confirmed attributions evaluated in the requested period by opportunities created in that same period. Those timestamps represent different cohorts; this is a period activity ratio, not necessarily a cohort conversion rate. The UI should label it accordingly or a future RPC should use a consistent opportunity cohort.

**Release posture:** Do not claim these semantics are verified by the existing handler tests. Before presenting the dashboard as financially authoritative, reconcile per-event recovered counts to confirmed attribution and define a currency policy (single-currency enforcement, per-currency breakdown, or an explicit FX conversion source). No live SQL, migration, RLS, or function was changed during this audit.


## Supabase advisor snapshot — 2026-11-23

Read-only Security and Performance advisor checks returned:

- **11 tables** in the private `henvalt` schema have RLS enabled with no policies. This is consistent with service-role-only internal tables and means ordinary roles are denied by default; do not add blanket tenant policies just to silence the INFO finding.
- One WARN reports `henvalt.is_tenant_member(uuid)` as a `SECURITY DEFINER` RPC executable by `authenticated`. A direct read-only check confirms its body returns only whether `tenant_memberships` contains the supplied tenant for `auth.uid()`, uses a fixed `henvalt, pg_temp` search path, and is referenced by 25 tenant-isolation / membership RLS policies. `anon` cannot execute it. This is an intentional authorization helper, not a generic data-reading RPC; do not revoke or convert it without migrating all dependent policies.
- Auth leaked-password protection is disabled. This is an Auth configuration hardening item, not a database migration; it was not changed in this audit.
- One foreign key, `shopify_privacy_requests.tenant_id`, lacks a covering index. Consider a targeted index before privacy-request volume grows; no index was created.
- The advisor lists 64 unused indexes. The tenant has very little production-like traffic, so these are not evidence that the indexes are unnecessary. Do not drop them based on this snapshot.

No advisor remediation, grant change, RLS policy, Auth setting, index, or production database object was changed.

## Shopify webhook integrity evidence

The n8n ingest workflow's Webhook node has `rawBody=true`; the n8n Webhook implementation places the exact raw request bytes in the binary `data` property while retaining parsed JSON in `body`. The workflow passes the base64 binary bytes and `X-Shopify-Hmac-Sha256` header to the private `verify_shopify_webhook_hmac` RPC before tenant resolution and event ingestion. Read-only tenant records show 130 webhook events reached the ingest ledger after that verification step: 129 processed and one failed business validation. This is evidence that historical webhook HMAC verification and ingestion worked; it is not evidence of a current webhook delivery today.

The one failed webhook was a `checkouts/update` event from 2026-11-02. Its recorded processing error was `missing_checkout_data`: checkout ID and customer email were not both available to create a recovery opportunity. It was not an HMAC failure. The latest Shopify webhook event was received 2026-11-14 15:44:42 UTC; the latest pixel event was received 2026-11-14 17:44:38 UTC. The pipeline has no fresh event evidence after those timestamps.


## Shopify ingress and test-store verification — 2026-11-23

The OAuth callback's persisted registration audit for this tenant (2026-11-13 05:35:26 UTC) confirms all 12 expected HENVALT webhook topics were created and re-read as verified at `https://henvalt-clean-ingress-v1.chmuhammadrehan18.workers.dev/shopify/webhooks`. Topics include checkout/cart events, order lifecycle, refunds, failed transactions, consent updates and app uninstall. This is stronger evidence than the Shopify connector's separate app-scoped webhook view, which is not the HENVALT OAuth app context.

Cloudflare account inspection confirms the `henvalt-clean-ingress-v1` Worker exists and has the expected `N8N_INGEST_URL` binding pointing to `https://n8n.henvalt.com/webhook/henvalt/ingest`; `SHOPIFY_API_SECRET` is a secret binding (its value was not read). The deployed Worker verifies Shopify HMAC over the raw request body, validates shop/topic/webhook headers, forwards the original raw body and relevant Shopify headers to n8n, and returns a retryable gateway error when forwarding fails. The deployment is configured with Workers Logs and persisted invocation logs enabled.

A source/deployment drift was found: the deployed Worker script differs from the current repository `cloudflare/worker.js` (the deployed version has explicit missing-binding and upstream-network error handling; the repository source has a 1 MB body limit and a slightly different response contract). No Worker was changed or redeployed during this audit. Reconcile this in a dedicated ingress-maintenance change before the next Worker deployment; do not overwrite the live script blindly.

The connected Shopify store is `ur4jvw-nz.myshopify.com` and its plan is trial. The connector reports: “Plan: trial — you'll need to upgrade before you can start selling and unlock full features”. This is a practical constraint on generating a real paid checkout/order test; it does not invalidate the historical webhook registrations or the historical HMAC-verified events.

The pixel collector Worker is also present with the expected Supabase URL and publishable key bindings, plus a secret collector binding and rate limiter. The tenant has 35 historical pixel events (19 page views, 10 product views, 6 add-to-cart events), latest received 2026-11-14 17:44:38 UTC. There is still no fresh pixel or webhook event evidence after 14 November.


## Financial metric integrity correction — 2026-11-23

The earlier live RPC audit identified cross-currency aggregation and a recovered-order predicate mismatch. A candidate correction is now on this PR branch.

- `control_plane_dashboard_summary` counts recovered orders from distinct confirmed `order_attributions`, not `opportunities.status='RECOVERED'`. Its per-event breakdown uses the same attribution predicate and adds an `unclassified` bucket for confirmed attributions without a matching opportunity, so the event counts reconcile to the headline. Recent activity labels a status-only RECOVERED opportunity as `unverified` until a confirmed attribution exists.
- Confirmed, billable recovery revenue is never summed across unlike currencies. The summary returns `revenueByCurrency`; if the selected period contains multiple or malformed currency codes, the headline total is null and the UI displays a multiple-currency state instead of formatting a combined amount in one currency.
- The revenue series is withheld for a mixed-currency current period. A single-currency current series remains available when only the previous comparison period has a different or mixed currency, but previous-period revenue and percentage change are null.
- The dashboard handler aggregates multiple ledger rows for one opportunity only when every row uses the same currency. It does not take an arbitrary first row or add unlike currencies. Activity rows use the ledger row's currency; a mixed-currency opportunity has no single numeric amount.
- The UI displays per-currency totals and an explicit mixed-currency message; null financial values render as an em dash, not zero.

Candidate migration: `supabase/migrations/202611230002_dashboard_currency_attribution_integrity.sql`.

Acceptance covers mixed USD/GBP rows, per-currency totals, malformed currency codes, current-vs-previous currency mismatch, single-currency trend retention, zero-ledger default currency, confirmed attribution count reconciliation, status-only recovered opportunities, and service-role-only RPC grants.

**Validation status:** Deno type-check and dashboard handler tests passed on the latest candidate head. The dedicated PostgreSQL 17 currency/attribution workflow is running against the final acceptance fixture; no production SQL or RPC has been changed. This remains draft candidate code and requires explicit review before deployment.

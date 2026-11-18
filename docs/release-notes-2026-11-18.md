# HENVALT preparation-branch release notes — 18 November 2026

**Release type:** engineering preparation; not a production release  
**Branch:** `prep/public-app-hardening-2026-11-15`  
**Pull request:** [#6](https://github.com/henvalt/henvalt-shopify-app/pull/6)  
**Production status:** unchanged

## Added and hardened

### Recovery orchestration and database contracts

- Migration 042 adds atomic exact-store checkout/pixel recovery work leases,
  bounded retries, fresh lease identity on reclaim and stale-worker rejection.
- Migration 043 adds idempotent checkout intervention materialization.
- Disposable PostgreSQL integration and true concurrent worker tests cover
  lease exclusion, retry and completion semantics.
- Existing candidate migrations 001–043 pass against the synthetic PostgreSQL
  17 baseline; none were applied to production.

### Trusted ingress and delivery boundaries

- Added a shared bounded streaming request reader.
- Checkout delivery now enforces a 160 KB body ceiling, JSON object shape,
  strict field allowlist, UTF-8 validity and content-type validation.
- Signed MailerSend webhook ingress now enforces a 1 MB streaming limit before
  forwarding the unchanged raw bytes to signature verification.
- Malformed body handling is bounded and does not log recipient or secret data.

### Dashboard correctness and resilience

- Added strict Gregorian date-only and inclusive date-range validation.
- Both dashboard API routes reject impossible dates, reversed ranges and
  ranges longer than 366 days.
- Auth, database and summary requests have bounded network deadlines.
- The browser dashboard aborts superseded requests, ignores stale responses,
  invalidates in-flight work on sign-out and clears merchant metrics from the
  rendered view.
- Added accessible live status regions and HTML-escaping regression coverage.

### CI, security and release controls

- Added `npm test` for all repository Node tests.
- Added `npm run check` for the configured Edge Function type checks.
- Added automated Gitleaks scanning; full Git history is fetched for the scan.
- Added regression tests for dashboard request races, date parsing, HTML
  escaping, sensitive-field isolation and manual-only Shopify deployment.
- Shopify unreleased-version preparation and production release now require
  explicit manual workflow dispatch confirmation from `main`.

## Validation evidence

The latest successful candidate validation reported:

- 322/322 repository Node tests passed.
- 209/209 focused V2 contract tests passed.
- Configured Deno Edge Function checks passed.
- Candidate migrations 001–043 applied successfully to disposable PostgreSQL.
- Two-store isolation, cost reservation, attribution/refund, privacy and
  concurrent recovery work-claim SQL tests passed.
- Gitleaks secret scan passed.
- Shopify configuration/static validation passed; app deployment was skipped.

See the [GitHub Actions runs](https://github.com/henvalt/henvalt-shopify-app/actions)
and PR #6 for current branch-head checks.

## Explicitly not included

- No production Supabase migration or Edge Function deployment.
- No Cloudflare Worker deployment or Pages production deployment.
- No n8n workflow edit, execution, publication or cutover.
- No Shopify app version preparation or production release.
- No customer email, billing transaction or purchase.
- No PR merge.

## Remaining launch gates

Public app ownership and configuration, production database lineage/migration
parity, three-workflow V2 cutover, trusted server-side message rendering,
Shopify protected customer data approval, provider/sender/billing setup,
real consent-eligible end-to-end recovery and attribution, privacy export/
redaction completion, dashboard deployment and operational rollback remain
open. This branch is not launch-ready.

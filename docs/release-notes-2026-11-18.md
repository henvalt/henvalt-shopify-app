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
- Existing candidate migrations 001–045 pass against the synthetic PostgreSQL
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

- 330/330 repository Node tests passed.
- 209/209 focused V2 contract tests passed.
- Configured Deno Edge Function checks passed.
- Candidate migrations 001–045 applied successfully to disposable PostgreSQL.
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

## 19 November — trusted recovery message and provider-safety batch

- Added migration 044 with service-role-only
  `resolve_shopify_recovery_message_context_v2(work_type,work_id)`. It
  returns only a canonical exact-store domain and an allowlisted recovery
  opportunity type; it returns no customer PII, secrets or delivery authority.
- Added the shared server-side `recovery-message-v2.mjs` renderer for checkout,
  cart and browse copy. The only merchant-specific display value is the
  verified sender name, escaped before HTML insertion.
- Changed checkout and pixel delivery endpoints to accept only their opaque
  work identifier. Caller-provided subject, HTML, text and other extra fields
  are rejected. n8n no longer owns message rendering.
- Added an exact verified MailerSend sender-domain preflight. Both HTML and
  plain-text unsubscribe insertion must be enabled; missing/unavailable
  settings block the send. All three templates include MailerSend's
  `{{unsubscribe}}` placeholder.
- Hardened checkout provider ambiguity to match the pixel path: network errors,
  408/5xx, missing message IDs and post-request ledger errors are AMBIGUOUS,
  preserve cost reservation and cannot be blindly retried.
- Added a disposable PostgreSQL exact-store pixel message-context assertion
  to the concurrent work-claim fixture and expanded Node regression coverage
  for escaping, safe domains, opaque-only inputs and unsubscribe settings.

The renderer intentionally links to the canonical Shopify store root rather
than fabricating a checkout permalink. Product-level personalization and
checkout deep links remain future work requiring a trusted exact-store source.
The n8n production workflows remain unchanged; no provider send occurred.

## 19 November — pre-permit verified sender resolution

- Added migration 045, `202611190002_shopify_sender_profile_preflight_v2.sql`,
  with a service-role-only sender resolver bound to the exact Shopify
  connection, active app, active tenant, active provider and verified sender.
- Checkout delivery now resolves the sender profile and verifies MailerSend
  domain unsubscribe settings plus the exact V2 webhook URL/event set before
  Shopify recipient lookup and before issuing/consuming the one-use permit.
- Checkout rechecks the consumed permit's sender email/name against the
  preflight snapshot before rendering/submission.
- Pixel delivery performs the same MailerSend readiness check before permit
  issue. Missing configuration therefore creates no attempt or cost
  reservation in either flow.
- Disposable PostgreSQL coverage now tests positive checkout and pixel message
  contexts and exact-store sender-profile resolution, including a cross-store
  rejection case.

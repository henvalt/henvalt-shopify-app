# HENVALT — Shopify recovery platform

HENVALT is a Shopify recovery platform intended to identify abandoned checkout,
cart and browse opportunities, evaluate eligibility, send merchant-branded
recovery messages, reconcile Shopify orders and refunds, and measure only
evidence-backed recovered revenue.

## Release status

**Preparation branch only — not launch-ready and not approved for production.**

This repository contains a candidate V2 architecture and its validation
suite. A passing CI run proves that the candidate code works against the
disposable PostgreSQL fixture and static contracts; it does not prove that
production Supabase, Cloudflare, Shopify or n8n are running that code.

The current PR is [#6](https://github.com/henvalt/henvalt-shopify-app/pull/6),
on branch `prep/public-app-hardening-2026-11-15`. It is draft, open and
unmerged.

### Verified candidate branch

- App-aware Shopify OAuth state/finalization and exact app/store identity.
- Raw-body Shopify webhook verification and exact-store event projection.
- Exact-store customer, session, checkout, order and refund identity graph.
- Checkout and pixel cart/browse recovery candidates and generalized
  opportunity records.
- Checkout intervention materialization and atomic, leased recovery work
  claims for the existing three-workflow architecture.
- Separate checkout and pixel delivery authorization boundaries, current
  Shopify consent/contact checks, single-use permits and merchant-wide
  provider-cost reservations.
- Signed MailerSend event intake, suppression and ambiguous-attempt
  reconciliation.
- Confirmed order/refund attribution and non-charging performance-fee
  measurements.
- Exact-store privacy receipt processing, export artifact lifecycle and
  fail-closed redaction/retention boundaries.
- An exact-store V2 dashboard read model and a candidate merchant dashboard.
- Bounded streaming request parsing, strict dashboard date validation,
  request cancellation, sign-out data clearing and bounded backend timeouts.

### Verified live baseline (read-only audit)

The latest integrated runtime audit recorded:

- Production Supabase had 178 applied migrations, latest
  `20261114174204`; none of candidate migrations 001–043 were in its
  migration history.
- Candidate V2 relations were absent from the live `henvalt` schema.
- Four active Shopify connections existed across three tenants, including
  one tenant with multiple active stores.
- Live operational tables did not carry immutable Shopify connection lineage
  across the full V1 recovery/order/revenue graph.
- The active three n8n workflows still used legacy tenant-scoped RPCs.
- The live dashboard did not yet use the candidate exact-store V2 read model.
- No real recovered order, confirmed attribution, revenue-ledger row or
  billing measurement was evidenced in the audited live data.

The audit and its dependency-ordered plan are documented in
[the integrated launch execution record](docs/launch-readiness-execution-2026-11-18.md)
and [the n8n V2 cutover boundary](docs/n8n-v2-cutover-boundary.md).

## Architecture

HENVALT is a serverless, multi-system product. It is not one long-running
application process, so a single Docker image would not represent its actual
deployment topology.

| Component | Responsibility | Candidate/live boundary |
|---|---|---|
| Shopify app and OAuth | Merchant install, app identity, scopes and token lifecycle | Candidate V2 OAuth is branch-only; current app config still points to legacy settings |
| Cloudflare Worker | Shopify raw webhook ingress and forwarding | Existing live Worker is legacy; candidate Worker source must be compared before any deployment |
| Supabase Edge Functions | Trusted API boundaries, Shopify lookups, delivery, dashboard and privacy | Several legacy functions are live; V2 functions are branch-only |
| Supabase PostgreSQL | Exact-store identity, recovery state, permits, provider events, attribution and fee measurements | Candidate migrations 001–043 are not applied to production |
| n8n | Scheduled recovery orchestration and delivery handoff | Exactly three production workflows remain active; they are not V2-wired |
| MailerSend | Provider submission and signed delivery/suppression events | V2 provider integration is candidate code; production sender/billing readiness is unverified |
| Cloudflare Pages | Merchant dashboard static UI | The production Pages project is connected to `main`; this branch is preview-only until merged |

### The three-workflow rule

Do not create a fourth HENVALT workflow.

1. `HENVALT_INGEST` — verified ingress routing; must not duplicate V2 webhook
   projection into the legacy canonical-event path.
2. `HENVALT_RECOVERY` — scheduled discovery, promotion, intervention
   materialization, exact-store claim and synchronous handoff.
3. `HENVALT_DELIVERY` — final V2 checkout/pixel delivery routing and result
   handling. Recipient email, Shopify access tokens, MailerSend API tokens and
   fingerprint secrets must never enter n8n item data or execution logs.

The active workflows have not been edited, published, executed or cut over by
this preparation work. See
[docs/n8n-v2-cutover-boundary.md](docs/n8n-v2-cutover-boundary.md).

## Repository layout

- `dashboard/` — static merchant dashboard candidate.
- `cloudflare/` — Worker and ingress source.
- `supabase/functions/` — Edge Functions and shared runtime helpers.
- `supabase/migrations/` — candidate database migrations.
- `supabase/config.toml` — function JWT verification configuration.
- `extensions/henvalt-pixel/` — Shopify Web Pixel extension source.
- `tests/` — Node contract/regression tests and SQL integration fixtures.
- `tests/sql/` — disposable PostgreSQL integration and concurrency tests.
- `.github/workflows/` — validation and manually gated Shopify preparation /
  release workflows.
- `docs/` — architecture, lineage, privacy, cutover and launch records.

## Local validation

Requirements:

- Node.js 22 or later.
- Deno 2.x.
- PostgreSQL 17 and `psql` for running the SQL integration suite locally.

No Node runtime dependencies are required by the repository test/check scripts.

```bash
npm test
npm run check
```

- `npm test` runs every `tests/*.test.mjs` file.
- `npm run check` type-checks the OAuth, checkout delivery, pixel delivery,
  MailerSend webhook and dashboard Edge Functions.

The GitHub Actions validation additionally:

- runs Gitleaks secret scanning;
- runs the complete Node regression suite and focused V2 contracts;
- checks the configured Edge Functions with Deno;
- creates a disposable PostgreSQL 17 database;
- applies candidate migrations 001–043 in order;
- executes two-store isolation, privacy, consent, attribution, cost-reservation
  and true concurrent work-claim tests;
- validates Shopify TOML and extension source.

These jobs do not connect to or mutate production. The current successful
validation included 322/322 repository Node tests and 209/209 focused V2
contract tests.

## Runtime configuration and secrets

Never commit service-role keys, Shopify API secrets, offline access/refresh
tokens, MailerSend API tokens, fingerprint secrets or delivery bearer tokens.
Use the relevant provider's secret manager:

- Supabase Edge Function secrets and Supabase Vault for server-held
  credentials.
- Cloudflare Worker secrets for Worker-only secrets.
- GitHub Actions repository secrets for CI deployment credentials.
- n8n credential storage for service credentials used by the three workflows.

Known function environment names in this repository include:

| Function / boundary | Required environment names |
|---|---|
| Legacy Shopify OAuth | `SHOPIFY_API_KEY`, `SHOPIFY_API_SECRET`, `SHOPIFY_REDIRECT_URI`; optional `SHOPIFY_SCOPES` |
| Checkout delivery V2 | `SUPABASE_URL`, `SUPABASE_SERVICE_ROLE_KEY`, `HENVALT_DELIVERY_AUTH_TOKEN` |
| Pixel delivery V2 | `SUPABASE_URL`, `SUPABASE_SERVICE_ROLE_KEY`, `HENVALT_PIXEL_DELIVERY_AUTH_TOKEN` |
| MailerSend webhook V2 | `SUPABASE_URL`, `SUPABASE_SERVICE_ROLE_KEY` |
| Merchant dashboard | `SUPABASE_URL`, `SUPABASE_SERVICE_ROLE_KEY`, `SUPABASE_ANON_KEY` |
| Shopify-session dashboard | `SUPABASE_URL`, `SUPABASE_SERVICE_ROLE_KEY`, `SHOPIFY_API_KEY`, `SHOPIFY_API_SECRET` |

The V2 delivery bearer tokens must be high-entropy, independently generated
secrets. Do not reuse one token across the checkout and pixel endpoints.
Do not place secret values in this README, app TOML, Worker vars, browser code,
n8n item payloads or GitHub source.

The public Shopify client ID and Supabase publishable/anon key are identifiers
intended for client configuration; they are not substitutes for server
credentials.

## Deployment topology and safety

### Supabase

Candidate migrations 001–043 and V2 Edge Functions are not deployed to the
audited production project. The live project has a separate migration history
and legacy operational schema. **Do not run `supabase db push` or deploy
candidate functions until the production schema has been reconciled and an
approved staged migration/rollback plan exists.**

### Cloudflare Worker

`wrangler.toml` identifies the existing legacy ingress Worker
`henvalt-clean-ingress-v1`. Its configuration is not a ready-to-deploy
definition for the candidate V2 Worker. Compare the live Worker source and
secret bindings before any Worker operation. Do not run `wrangler deploy`
from this branch.

### Cloudflare Pages

The production Pages project `henvalt-dashboard` is connected to the
repository's `main` branch, with build root `dashboard/` and output
directory `.`. Pull-request branch builds are previews; merging to `main`
can publish production. This PR has not been merged and no Pages production
deployment was made by this work.

### Shopify app

The checked-in `shopify.app.toml` is not release-ready: it still points to
legacy application/privacy URLs and enables the legacy install flow. The
Partner-owned app identity, redirect URLs, requested protected customer data
access and Shopify-generated Web Pixel UID must be confirmed by the current
app owner before an app version is prepared.

Shopify preparation and production release workflows now require an explicit
manual `workflow_dispatch` confirmation from `main`. A normal push or PR
cannot release the app. The preparation workflow creates an unreleased version
only; the separate release workflow is the production release boundary.

### Why there is no Dockerfile

The deployed product consists of Supabase Edge Functions/PostgreSQL,
Cloudflare Worker/Pages, Shopify configuration and three n8n workflows.
A Dockerfile would not deploy or validate those provider-managed services and
would imply a single-container runtime that does not exist. The repository's
provider-specific CI/CD workflows and runbooks are the appropriate deployment
configuration.

## Launch blockers — do not represent as completed

1. **App ownership and configuration:** obtain owner-controlled Partner app
   identity and credentials; replace the legacy application URL, callback,
   privacy endpoint and install-flow settings; generate and validate the
   Shopify Pixel UID.
2. **Production database parity:** reconcile the 178-migration live baseline
   with candidate migrations 001–043, map every V1/V2 foreign-key lineage and
   resolve historical ambiguous rows before any migration.
3. **Runtime cutover:** design, test and explicitly approve the V2 adapters
   for the three existing n8n workflows. Prevent duplicate V1/V2 ingestion or
   sends.
4. **Message rendering:** implement a trusted server-side renderer and
   approved template/context contract. Current delivery functions accept
   caller-supplied subject/body content; do not wire these into n8n or send
   customer messages until that contract is complete and tested.
5. **Provider and billing readiness:** configure an owner-controlled
   MailerSend account, verified sender, Vault references, provider cost and
   merchant-funded caps. Confirm the performance percentage and billing
   principal; fee measurements are non-charging records.
6. **Protected customer data:** obtain Shopify approval for the required
   customer email access and confirm scopes/fields on an owner-controlled
   test store.
7. **End-to-end proof:** run a controlled, consent-eligible checkout/cart/browse
   event through the verified ingress, recovery claim, trusted delivery,
   signed provider event, Shopify order/refund projection and confirmed
   attribution. A provider-accepted email is not recovered revenue.
8. **Privacy lifecycle:** finish exact-store export delivery, customer/shop
   redaction and retention approval; legacy tenant-scoped lineage remains an
   explicit blocker.
9. **Merchant dashboard:** deploy the exact-store API/read model only after
   the matching migrations and authorization contract are live; verify
   two-store switching and reconciliation against source records.
10. **Operational readiness:** monitoring, retry/reconciliation queues,
    incident response, rollback, privacy deadlines, app review and support
    processes must be approved before launch.

## Release documentation

- [Integrated launch execution and verified live baseline](docs/launch-readiness-execution-2026-11-18.md)
- [Three-workflow V2 cutover boundary](docs/n8n-v2-cutover-boundary.md)
- [Trusted recovery message rendering and unsubscribe contract](docs/recovery-message-rendering-v2.md)
- [Checkout recovery eligibility](docs/shopify-checkout-recovery-eligibility-v2.md)
- [Contact resolution and delivery boundary](docs/shopify-contact-resolution-delivery-v2.md)
- [Exact-store revenue attribution](docs/shopify-exact-store-revenue-attribution-v2.md)
- [Exact-store privacy lifecycle](docs/shopify-exact-store-privacy-lifecycle-v2.md)
- [Preparation-branch release notes](docs/release-notes-2026-11-18.md)
- [Staged deployment and rollback runbook](docs/deployment-and-release-runbook-2026-11-18.md)

**No production migration, Edge Function, Worker, n8n workflow, Shopify app
release, Pages deployment, customer email or billing transaction was performed
by this preparation work.**
